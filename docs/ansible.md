# Ansible — Configuration Management

## Role in the Platform

Ansible handles OS-level and runtime configuration of EKS worker nodes.
It runs after Terraform creates the node groups and before ArgoCD begins workload deployment.
It is invoked by GitHub Actions as part of the provisioning pipeline.

Ansible does NOT manage Kubernetes resources — that is ArgoCD’s responsibility.

## Directory Structure

```
src/ansible/
├── ansible.cfg                     # Local config — roles priority, SSH, vault, become
├── site.yml                        # Main playbook entry point
├── requirements.yml                # Ansible Galaxy collection dependencies
├── inventory/
│   └── aws_ec2.yml                 # Dynamic inventory (AWS EC2 plugin)
├── group_vars/
│   ├── all/
│   │   ├── main.yaml               # Common variables
│   │   └── vault.yaml              # Encrypted secrets (Ansible Vault)
│   ├── system_nodes/
│   │   ├── main.yaml               # System node group variables
│   │   └── vault.yaml
│   └── workload_nodes/
│       ├── main.yaml               # Workload node group variables
│       └── vault.yaml
├── roles/                          # Local project-specific roles (highest priority)
│   ├── os_hardening/
│   ├── container_runtime/
│   ├── node_labels/
│   └── eks_bootstrap/
└── common_roles/                   # Shared/external roles (lower priority)
    └── role_prepare_node/          # Shared node preparation role (role_ prefix)
```

## ansible.cfg

Local `ansible.cfg` is committed to the repo and applies automatically when Ansible
is run from the `src/ansible/` directory.

```ini
[defaults]
roles_path            = common_roles:roles
ansible_managed       = This file is managed by Ansible. Changes will be overwritten. Generated on %Y-%m-%d %H:%M:%S
vault_password_file   = .vault_pass

[inventory]
# Dynamic inventory via aws_ec2 plugin

[privilege_escalation]
become_method   = sudo
become_user     = root
become_ask_pass = False

[ssh_connection]
ssh_args = -o StrictHostKeyChecking=no -o ProxyCommand="aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p"
```

### `roles_path = common_roles:roles`

Ansible resolves role names left to right through the path list.

* `common_roles/` — Ansible Galaxy roles installed via `ansible-galaxy role install -p common_roles/`. Listed first so Galaxy-installed roles are found without scanning the local `roles/` tree first.
* `roles/` — local project-specific roles. Role names here are distinct from Galaxy role names so there is no collision; the path ordering is for lookup efficiency, not override.

To install Galaxy roles into the correct location:

```bash
ansible-galaxy role install -p common_roles/ -r requirements.yml
```

### `.vault_pass`

`.vault_pass` is listed in `.gitignore` — it must never be committed.
In GitHub Actions, the vault password is injected from AWS Secrets Manager at runtime:

```bash
# In GHA workflow step
aws secretsmanager get-secret-value \
  --secret-id /platform/ansible-vault-pass \
  --query SecretString --output text > src/ansible/.vault_pass
```

The file is written to disk only for the duration of the job and not persisted.

## Role Naming Convention

|     |     |     |     |
| --- | --- | --- | --- |
| Location | Prefix | Example | Purpose |
| `common_roles/` | `role_` | `role_prepare_node` | Shared across projects |
| `roles/` | none | `os_hardening` | Local to this platform |

The `role_` prefix on shared roles makes it immediately clear in a playbook whether
a role is shared or local:

```yaml
roles:
  - role_prepare_node        # ← shared role from common_roles/
  - os_hardening             # ← local role from roles/
  - container_runtime        # ← local role from roles/
```

## Dynamic Inventory

Inventory is generated from AWS EC2 tags using the `aws_ec2` plugin.
No static inventory files are maintained for tenant clusters.

```yaml
# inventory/aws_ec2.yml
plugin: aws_ec2
regions:
  - "{{ lookup('env', 'AWS_REGION') }}"
filters:
  tag:TenantID: "{{ lookup('env', 'TENANT_ID') }}"
  tag:ManagedBy: terraform
  instance-state-name: running
keyed_groups:
  - key: tags['node-role']
    prefix: node_role
hostnames:
  - private-ip-address
compose:
  ansible_host: private_ip_address
```

This produces inventory groups `node_role_system` and `node_role_workload`
matching the EC2 tags applied by Terraform.

## Connection — AWS SSM

Nodes are accessed via SSM — no SSH keys, no bastion host.
The `ssh_args` in `ansible.cfg` proxy all connections through `aws ssm start-session`.

Requirements:

* SSM Agent running on nodes (pre-installed on Amazon Linux 2 / Bottlerocket)
* Node IAM role has `AmazonSSMManagedInstanceCore` policy
* Ansible controller has `ssm:StartSession` permission (via IRSA or GHA role)

## Playbook Catalog

### `site.yml` — Full Node Bootstrap

Applied during tenant onboarding. Runs all roles in sequence:

```yaml
---
- name: Prepare all nodes
  hosts: all
  become: true
  roles:
    - role_prepare_node       # common_roles — chrony, base packages, users, dirs
    - os_hardening            # roles — CIS hardening
  tags:
    - prepare

- name: Configure container runtime
  hosts: all
  become: true
  roles:
    - container_runtime       # roles — containerd config, registry mirrors
  tags:
    - runtime

- name: Bootstrap EKS node
  hosts: all
  become: true
  roles:
    - eks_bootstrap           # roles — kubelet flags, node labels/taints
  tags:
    - eks

- name: Configure node monitoring agent
  hosts: all
  become: true
  roles:
    - role_prepare_node       # reuses shared role for node_exporter if included
    - node_labels             # roles — label/taint reconciliation post-join
  tags:
    - monitoring
```

### `hardening.yml` — Compliance Re-run

Runs `os_hardening` only against all nodes. Used for quarterly CIS compliance checks
without touching runtime configuration.

### `update-runtime.yml` — containerd Config Update

Updates containerd configuration across an existing node group
(e.g., adding a registry mirror, adjusting cgroup driver).

## Role Details

### `common_roles/role_prepare_node`

Shared role — mirrors the pattern from the reference project.

Tasks:

* Install base Debian/Ubuntu packages (curl, chrony, tmux, vim, etc.)
* Configure chrony (NTP) from template
* Create system groups, users, directories
* Add `/etc/hosts` entries

Defaults in `role_prepare_node/defaults/main.yaml`:

```yaml
prepare_node_debian_packages:
  - name: bash-completion
  - name: ca-certificates
  - name: curl
  - name: chrony
  - name: tmux
  - name: vim
  - name: unzip
prepare_node_ntp_server: lv.pool.ntp.org
prepare_node_config_chrony: true
prepare_node_system_groups: []
prepare_node_system_users: []
prepare_node_system_folders: []
prepare_node_hosts: []
```

Override in `group_vars/all/main.yaml` to add platform-specific packages and users.

### `roles/os_hardening`

CIS Amazon Linux 2 / Debian hardening:

* Disable unused filesystems
* Configure auditd
* SSH daemon hardening (`PermitRootLogin no`, key-only auth)
* PAM lockout policy
* Sysctl tuning for Kubernetes networking requirements

### `roles/container_runtime`

Configures containerd for EKS:

* `/etc/containerd/config.toml` from template
* `SystemdCgroup = true`
* Private ECR registry mirror
* Restart containerd service on config change

### `roles/eks_bootstrap`

Post-node-join configuration:

* Set kubelet extra args (`--node-labels`, `--register-with-taints`)
* Ensure kubelet is enabled and running
* Apply any additional sysctl required by Kubernetes

### `roles/node_labels`

Reconciles node labels and taints after node has joined the cluster.
Uses `kubectl label` and `kubectl taint` via the `kubernetes.core.k8s` module.
Runs only when the node is already visible in the Kubernetes API.

## Group Variables

```
group_vars/
├── all/
│   ├── main.yaml          # Platform-wide vars (region, tenant_id injected at runtime)
│   └── vault.yaml         # Encrypted: registry pull secrets, any node-level secrets
├── node_role_system/
│   ├── main.yaml          # System node overrides (taint config, label values)
│   └── vault.yaml
└── node_role_workload/
    ├── main.yaml          # Workload node overrides
    └── vault.yaml
```

`vault.yaml` files are encrypted with Ansible Vault. The vault password is never committed —
see `.vault_pass` section above.

Encrypt a file:

```bash
ansible-vault encrypt group_vars/all/vault.yaml
```

Edit in place:

```bash
ansible-vault edit group_vars/all/vault.yaml
```

## Running from GitHub Actions

```yaml
- name: Run Ansible bootstrap
  working-directory: ansible
  run: |
    # Write vault password (from AWS Secrets Manager, fetched earlier)
    echo "$VAULT_PASS" > .vault_pass
    chmod 600 .vault_pass

    ansible-playbook site.yml \
      -i inventory/aws_ec2.yml \
      -e "tenant_id=${{ inputs.tenant_id }}" \
      -e "aws_region=${{ inputs.aws_region }}" \
      --diff
  env:
    VAULT_PASS: ${{ steps.get-vault-pass.outputs.value }}
    AWS_REGION: ${{ inputs.aws_region }}
    ANSIBLE_HOST_KEY_CHECKING: "False"
```

## Idempotency

All roles are fully idempotent. Re-running `site.yml` against a configured node
produces zero changes. This is verified in CI by running the playbook twice and
asserting the second run reports `changed=0`.
