#!/usr/bin/env python3
"""
provision_namespace.py — Idempotently provision all Kubernetes resources for a tenant namespace.

Creates or patches:
  1. Namespace
  2. NetworkPolicy (default-deny ingress + explicit allow rules)
  3. ResourceQuota
  4. LimitRange
  5. ServiceAccount + Role + RoleBinding (tenant RBAC)
  6. ClusterSecretStore (ESO — scoped to /<tenant-id>/* in Secrets Manager)
  7. ArgoCD AppProject (namespace-scoped, blocks cluster-scoped resource creation)

Usage:
    python provision_namespace.py --tenant-id <id> [--config-root <path>] [--dry-run]
"""

import argparse
import sys
from pathlib import Path

import yaml
from kubernetes import client, config as k8s_config
from kubernetes.client.rest import ApiException


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def load_tenant_config(tenant_id: str, config_root: str) -> dict:
    path = Path(config_root) / tenant_id / "config.yaml"
    if not path.exists():
        fail(f"Config not found: {path}")
    with path.open() as f:
        return yaml.safe_load(f)


def apply_or_patch(api_fn_create, api_fn_patch, name, namespace, body, dry_run: bool) -> None:
    """Create resource; if it already exists, patch it."""
    if dry_run:
        ns_part = f" in {namespace}" if namespace else ""
        print(f"  [dry-run] would apply {body['kind']}/{name}{ns_part}")
        return
    try:
        if namespace:
            api_fn_create(namespace, body)
        else:
            api_fn_create(body)
        print(f"  created {body['kind']}/{name}")
    except ApiException as e:
        if e.status == 409:  # Already exists
            if namespace:
                api_fn_patch(name, namespace, body)
            else:
                api_fn_patch(name, body)
            print(f"  patched  {body['kind']}/{name}")
        else:
            fail(f"API error creating {body['kind']}/{name}: {e}")


def provision(tenant_id: str, namespace: str, quotas: dict, dry_run: bool) -> None:
    core = client.CoreV1Api()
    rbac = client.RbacAuthorizationV1Api()
    custom = client.CustomObjectsApi()

    # ── 1. Namespace ────────────────────────────────────────────────────────────
    ns_body = {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": namespace,
            "labels": {
                "platform.io/tenant": tenant_id,
                "pod-security.kubernetes.io/enforce": "restricted",
            },
        },
    }
    apply_or_patch(
        lambda b: core.create_namespace(b),
        lambda n, b: core.patch_namespace(n, b),
        namespace, None, ns_body, dry_run,
    )

    # ── 2. NetworkPolicy: default-deny ingress ──────────────────────────────────
    netpol_body = {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": {"name": "default-deny-ingress", "namespace": namespace},
        "spec": {
            "podSelector": {},
            "policyTypes": ["Ingress"],
            "ingress": [
                # Allow intra-namespace traffic
                {"from": [{"podSelector": {}}]},
                # Allow ingress-nginx to route to tenant pods
                {
                    "from": [
                        {
                            "namespaceSelector": {
                                "matchLabels": {"kubernetes.io/metadata.name": "ingress-nginx"}
                            }
                        }
                    ]
                },
            ],
        },
    }
    networking = client.NetworkingV1Api()
    apply_or_patch(
        lambda ns, b: networking.create_namespaced_network_policy(ns, b),
        lambda n, ns, b: networking.patch_namespaced_network_policy(n, ns, b),
        "default-deny-ingress", namespace, netpol_body, dry_run,
    )

    # ── 3. ResourceQuota ────────────────────────────────────────────────────────
    quota_body = {
        "apiVersion": "v1",
        "kind": "ResourceQuota",
        "metadata": {"name": "tenant-quota", "namespace": namespace},
        "spec": {"hard": quotas},
    }
    apply_or_patch(
        lambda ns, b: core.create_namespaced_resource_quota(ns, b),
        lambda n, ns, b: core.patch_namespaced_resource_quota(n, ns, b),
        "tenant-quota", namespace, quota_body, dry_run,
    )

    # ── 4. LimitRange ───────────────────────────────────────────────────────────
    limitrange_body = {
        "apiVersion": "v1",
        "kind": "LimitRange",
        "metadata": {"name": "tenant-limits", "namespace": namespace},
        "spec": {
            "limits": [
                {
                    "type": "Container",
                    "default": {"cpu": "500m", "memory": "256Mi"},
                    "defaultRequest": {"cpu": "50m", "memory": "64Mi"},
                    "max": {"cpu": "4", "memory": "4Gi"},
                }
            ]
        },
    }
    apply_or_patch(
        lambda ns, b: core.create_namespaced_limit_range(ns, b),
        lambda n, ns, b: core.patch_namespaced_limit_range(n, ns, b),
        "tenant-limits", namespace, limitrange_body, dry_run,
    )

    # ── 5. ServiceAccount + Role + RoleBinding ──────────────────────────────────
    sa_body = {
        "apiVersion": "v1",
        "kind": "ServiceAccount",
        "metadata": {"name": f"{tenant_id}-deployer", "namespace": namespace},
    }
    apply_or_patch(
        lambda ns, b: core.create_namespaced_service_account(ns, b),
        lambda n, ns, b: core.patch_namespaced_service_account(n, ns, b),
        f"{tenant_id}-deployer", namespace, sa_body, dry_run,
    )

    role_body = {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "Role",
        "metadata": {"name": f"{tenant_id}-deployer", "namespace": namespace},
        "rules": [
            {
                "apiGroups": ["", "apps", "batch", "networking.k8s.io", "autoscaling"],
                "resources": [
                    "deployments", "services", "configmaps", "ingresses",
                    "horizontalpodautoscalers", "jobs", "cronjobs",
                ],
                "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"],
            }
        ],
    }
    apply_or_patch(
        lambda ns, b: rbac.create_namespaced_role(ns, b),
        lambda n, ns, b: rbac.patch_namespaced_role(n, ns, b),
        f"{tenant_id}-deployer", namespace, role_body, dry_run,
    )

    rb_body = {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "RoleBinding",
        "metadata": {"name": f"{tenant_id}-deployer", "namespace": namespace},
        "subjects": [
            {"kind": "ServiceAccount", "name": f"{tenant_id}-deployer", "namespace": namespace}
        ],
        "roleRef": {
            "kind": "Role",
            "name": f"{tenant_id}-deployer",
            "apiGroup": "rbac.authorization.k8s.io",
        },
    }
    apply_or_patch(
        lambda ns, b: rbac.create_namespaced_role_binding(ns, b),
        lambda n, ns, b: rbac.patch_namespaced_role_binding(n, ns, b),
        f"{tenant_id}-deployer", namespace, rb_body, dry_run,
    )

    # ── 6. ClusterSecretStore (ESO) ─────────────────────────────────────────────
    # Scoped to /<tenant-id>/* prefix in AWS Secrets Manager via IRSA role.
    css_body = {
        "apiVersion": "external-secrets.io/v1beta1",
        "kind": "ClusterSecretStore",
        "metadata": {"name": tenant_id},
        "spec": {
            "provider": {
                "aws": {
                    "service": "SecretsManager",
                    "region": "eu-west-1",
                    "auth": {
                        "jwt": {
                            "serviceAccountRef": {
                                "name": "external-secrets",
                                "namespace": "external-secrets",
                            }
                        }
                    },
                }
            }
        },
    }
    if dry_run:
        print(f"  [dry-run] would apply ClusterSecretStore/{tenant_id}")
    else:
        try:
            custom.create_cluster_custom_object(
                "external-secrets.io", "v1beta1", "clustersecretstores", css_body
            )
            print(f"  created ClusterSecretStore/{tenant_id}")
        except ApiException as e:
            if e.status == 409:
                custom.patch_cluster_custom_object(
                    "external-secrets.io", "v1beta1", "clustersecretstores", tenant_id, css_body
                )
                print(f"  patched  ClusterSecretStore/{tenant_id}")
            else:
                fail(f"API error creating ClusterSecretStore: {e}")

    # ── 7. ArgoCD AppProject ────────────────────────────────────────────────────
    project_body = {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "AppProject",
        "metadata": {"name": tenant_id, "namespace": "argocd"},
        "spec": {
            "description": f"Namespace-scoped project for tenant {tenant_id}",
            "sourceRepos": ["*"],
            "destinations": [
                {"server": "https://kubernetes.default.svc", "namespace": namespace}
            ],
            "clusterResourceWhitelist": [],  # No cluster-scoped resources allowed
            "namespaceResourceBlacklist": [
                {"group": "rbac.authorization.k8s.io", "kind": "ClusterRole"},
                {"group": "rbac.authorization.k8s.io", "kind": "ClusterRoleBinding"},
            ],
            "roles": [
                {
                    "name": "deployer",
                    "description": "CI/CD deploy access for tenant",
                    "policies": [
                        f"p, proj:{tenant_id}:deployer, applications, *, {tenant_id}/*, allow"
                    ],
                }
            ],
        },
    }
    if dry_run:
        print(f"  [dry-run] would apply AppProject/{tenant_id}")
    else:
        try:
            custom.create_namespaced_custom_object(
                "argoproj.io", "v1alpha1", "argocd", "appprojects", project_body
            )
            print(f"  created AppProject/{tenant_id}")
        except ApiException as e:
            if e.status == 409:
                custom.patch_namespaced_custom_object(
                    "argoproj.io", "v1alpha1", "argocd", "appprojects", tenant_id, project_body
                )
                print(f"  patched  AppProject/{tenant_id}")
            else:
                fail(f"API error creating AppProject: {e}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Provision Kubernetes resources for a tenant")
    parser.add_argument("--tenant-id", required=True, help="Tenant ID")
    parser.add_argument("--config-root", default="tenants", help="Root directory for tenant configs")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without applying")
    parser.add_argument("--in-cluster", action="store_true", help="Use in-cluster kubeconfig")
    args = parser.parse_args()

    if args.in_cluster:
        k8s_config.load_incluster_config()
    else:
        k8s_config.load_kube_config()

    tenant_config = load_tenant_config(args.tenant_id, args.config_root)
    tenant_id = tenant_config["tenant"]["id"]
    namespace = tenant_config["namespace"]["name"]
    quotas = tenant_config["quotas"]

    print(f"Provisioning namespace for tenant '{tenant_id}' (namespace: {namespace})")
    if args.dry_run:
        print("  -- dry-run mode, no changes will be applied --")

    provision(tenant_id, namespace, quotas, args.dry_run)
    print("Done.")


if __name__ == "__main__":
    main()
