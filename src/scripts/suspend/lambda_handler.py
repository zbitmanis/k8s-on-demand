"""
cluster_suspend Lambda — suspend and resume EKS node groups for cost saving.

Invoked by:
  - EventBridge scheduled rule  (action = suspend | resume)
  - Argo Workflow script step   (via boto3 Lambda.invoke)
  - Manual AWS Console / CLI    (for ad-hoc ops)

Actions
-------
suspend
    1. Describe all managed node groups for the cluster.
    2. Store each group's current {minSize, desiredSize} to SSM under
       /cluster-suspend/<cluster_name>/<nodegroup_name>.
    3. Set minSize=0, desiredSize=0 on every group.
    4. Tag each node group:  suspend:state=suspended,
                             suspend:suspended-at=<iso-timestamp>

resume
    1. Read stored sizes from SSM.
    2. Restore minSize + desiredSize on every group.
    3. Remove suspend tags.
    4. Wait (optional, controlled by WAIT_FOR_NODES env var) until at
       least one node per group reaches Ready state.

Environment variables (set by Terraform / Lambda config)
---------------------------------------------------------
CLUSTER_NAME      EKS cluster name                    (required)
AWS_REGION        AWS region                           (required)
SSM_PREFIX        SSM path prefix                     default: /cluster-suspend
WAIT_FOR_NODES    "true" to block until nodes ready   default: false
NODE_READY_TIMEOUT_SEC  seconds to wait               default: 600
"""

import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── clients (lazy-initialised for test mocking) ───────────────────────────────

_eks = None
_ssm = None
_ec2 = None


def eks_client():
    global _eks
    if _eks is None:
        _eks = boto3.client("eks", region_name=os.environ["AWS_REGION"])
    return _eks


def ssm_client():
    global _ssm
    if _ssm is None:
        _ssm = boto3.client("ssm", region_name=os.environ["AWS_REGION"])
    return _ssm


def ec2_client():
    global _ec2
    if _ec2 is None:
        _ec2 = boto3.client("ec2", region_name=os.environ["AWS_REGION"])
    return _ec2


# ── SSM helpers ───────────────────────────────────────────────────────────────

def _ssm_prefix(cluster: str) -> str:
    base = os.environ.get("SSM_PREFIX", "/cluster-suspend")
    return f"{base}/{cluster}"


def _store_nodegroup_sizes(cluster: str, nodegroup: str, min_size: int, desired_size: int):
    path = f"{_ssm_prefix(cluster)}/{nodegroup}"
    payload = json.dumps({"minSize": min_size, "desiredSize": desired_size})
    ssm_client().put_parameter(
        Name=path,
        Value=payload,
        Type="String",
        Overwrite=True,
    )
    logger.info("Stored sizes for %s/%s: %s", cluster, nodegroup, payload)


def _load_nodegroup_sizes(cluster: str, nodegroup: str) -> dict:
    path = f"{_ssm_prefix(cluster)}/{nodegroup}"
    try:
        resp = ssm_client().get_parameter(Name=path)
        return json.loads(resp["Parameter"]["Value"])
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ParameterNotFound":
            logger.warning("No stored sizes for %s/%s — defaulting to 1/1", cluster, nodegroup)
            return {"minSize": 1, "desiredSize": 1}
        raise


# ── node group helpers ────────────────────────────────────────────────────────

def _list_nodegroups(cluster: str) -> list[str]:
    paginator = eks_client().get_paginator("list_nodegroups")
    groups = []
    for page in paginator.paginate(clusterName=cluster):
        groups.extend(page["nodegroups"])
    return groups


def _describe_nodegroup(cluster: str, nodegroup: str) -> dict:
    return eks_client().describe_nodegroup(
        clusterName=cluster,
        nodegroupName=nodegroup,
    )["nodegroup"]


def _update_nodegroup_scaling(cluster: str, nodegroup: str, min_size: int, desired_size: int):
    eks_client().update_nodegroup_config(
        clusterName=cluster,
        nodegroupName=nodegroup,
        scalingConfig={
            "minSize": min_size,
            "desiredSize": desired_size,
        },
    )
    logger.info("Updated %s/%s → min=%d desired=%d", cluster, nodegroup, min_size, desired_size)


def _tag_nodegroup(cluster: str, nodegroup: str, tags: dict):
    ng = _describe_nodegroup(cluster, nodegroup)
    eks_client().tag_resource(
        resourceArn=ng["nodegroupArn"],
        tags=tags,
    )


def _untag_nodegroup(cluster: str, nodegroup: str, tag_keys: list[str]):
    ng = _describe_nodegroup(cluster, nodegroup)
    eks_client().untag_resource(
        resourceArn=ng["nodegroupArn"],
        tagKeys=tag_keys,
    )


# ── wait for nodes ─────────────────────────────────────────────────────────────

def _wait_for_nodes_ready(cluster: str, timeout: int = 600):
    """Block until at least one EC2 instance per node group is in service."""
    deadline = time.time() + timeout
    logger.info("Waiting up to %ds for node groups to become ready...", timeout)

    while time.time() < deadline:
        nodegroups = _list_nodegroups(cluster)
        all_ready = True
        for ng_name in nodegroups:
            ng = _describe_nodegroup(cluster, ng_name)
            desired = ng["scalingConfig"]["desiredSize"]
            if desired == 0:
                continue  # intentionally scaled to 0
            status = ng.get("status")
            if status != "ACTIVE":
                logger.info("  %s status=%s (waiting)", ng_name, status)
                all_ready = False
                break
        if all_ready:
            logger.info("All node groups active.")
            return
        time.sleep(30)

    raise TimeoutError(f"Nodes did not become ready within {timeout}s")


# ── core actions ──────────────────────────────────────────────────────────────

def suspend(cluster: str) -> dict:
    nodegroups = _list_nodegroups(cluster)
    if not nodegroups:
        return {"status": "noop", "reason": "no node groups found"}

    now_iso = datetime.now(timezone.utc).isoformat()
    suspended = []

    for ng_name in nodegroups:
        ng = _describe_nodegroup(cluster, ng_name)
        current_min = ng["scalingConfig"]["minSize"]
        current_desired = ng["scalingConfig"]["desiredSize"]

        if current_desired == 0:
            logger.info("Skipping %s — already at 0", ng_name)
            continue

        _store_nodegroup_sizes(cluster, ng_name, current_min, current_desired)
        _update_nodegroup_scaling(cluster, ng_name, min_size=0, desired_size=0)
        _tag_nodegroup(cluster, ng_name, {
            "suspend:state": "suspended",
            "suspend:suspended-at": now_iso,
        })
        suspended.append(ng_name)
        logger.info("Suspended %s (was min=%d desired=%d)", ng_name, current_min, current_desired)

    return {
        "status": "suspended",
        "cluster": cluster,
        "suspended_nodegroups": suspended,
        "suspended_at": now_iso,
    }


def resume(cluster: str) -> dict:
    nodegroups = _list_nodegroups(cluster)
    if not nodegroups:
        return {"status": "noop", "reason": "no node groups found"}

    resumed = []

    for ng_name in nodegroups:
        sizes = _load_nodegroup_sizes(cluster, ng_name)
        _update_nodegroup_scaling(
            cluster,
            ng_name,
            min_size=sizes["minSize"],
            desired_size=sizes["desiredSize"],
        )
        _untag_nodegroup(cluster, ng_name, ["suspend:state", "suspend:suspended-at"])
        resumed.append({"nodegroup": ng_name, **sizes})
        logger.info("Resumed %s → min=%d desired=%d", ng_name, sizes["minSize"], sizes["desiredSize"])

    if os.environ.get("WAIT_FOR_NODES", "false").lower() == "true":
        timeout = int(os.environ.get("NODE_READY_TIMEOUT_SEC", "600"))
        _wait_for_nodes_ready(cluster, timeout=timeout)

    return {
        "status": "resumed",
        "cluster": cluster,
        "resumed_nodegroups": resumed,
    }


# ── Lambda entrypoint ─────────────────────────────────────────────────────────

def handler(event: dict, context) -> dict:
    """
    Expected event payload:
        { "action": "suspend" | "resume" }

    The cluster name is read from the CLUSTER_NAME environment variable,
    set by Terraform in the Lambda configuration.
    """
    action = event.get("action", "").lower()
    cluster = os.environ["CLUSTER_NAME"]

    logger.info("cluster-suspend invoked: action=%s cluster=%s", action, cluster)

    if action == "suspend":
        result = suspend(cluster)
    elif action == "resume":
        result = resume(cluster)
    else:
        raise ValueError(f"Unknown action '{action}'. Must be 'suspend' or 'resume'.")

    logger.info("Result: %s", json.dumps(result))
    return result
