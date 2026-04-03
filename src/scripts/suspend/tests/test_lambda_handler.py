"""
Unit tests for the cluster-suspend Lambda handler.

Patterns:
  - moto mocks EKS and SSM — no real AWS calls
  - Each test follows Red / Green via explicit boto3 setup
  - CLUSTER_NAME and AWS_REGION injected via monkeypatch
"""

import json
import os

import boto3
import pytest
from moto import mock_aws

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# Reset module-level cached clients between tests
import importlib
import lambda_handler as lh


# ── fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(autouse=True)
def reset_clients():
    """Clear cached boto3 clients so moto mock takes effect each test."""
    lh._eks = None
    lh._ssm = None
    lh._ec2 = None
    yield
    lh._eks = None
    lh._ssm = None
    lh._ec2 = None


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    monkeypatch.setenv("AWS_REGION", "eu-west-1")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "eu-west-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")
    monkeypatch.setenv("CLUSTER_NAME", "platform-cluster")
    monkeypatch.setenv("SSM_PREFIX", "/cluster-suspend")
    monkeypatch.setenv("WAIT_FOR_NODES", "false")


@pytest.fixture
def eks_cluster_with_nodegroups():
    """Creates an EKS cluster + two node groups via moto."""
    with mock_aws():
        ec2 = boto3.client("ec2", region_name="eu-west-1")
        eks = boto3.client("eks", region_name="eu-west-1")
        iam = boto3.client("iam", region_name="eu-west-1")

        # IAM role for EKS
        role = iam.create_role(
            RoleName="eks-role",
            AssumeRolePolicyDocument=json.dumps({
                "Version": "2012-10-17",
                "Statement": [{"Effect": "Allow", "Principal": {"Service": "eks.amazonaws.com"}, "Action": "sts:AssumeRole"}],
            }),
        )["Role"]

        # VPC + subnets
        vpc = ec2.create_vpc(CidrBlock="10.0.0.0/16")["Vpc"]
        subnet_a = ec2.create_subnet(VpcId=vpc["VpcId"], CidrBlock="10.0.1.0/24", AvailabilityZone="eu-west-1a")["Subnet"]
        subnet_b = ec2.create_subnet(VpcId=vpc["VpcId"], CidrBlock="10.0.2.0/24", AvailabilityZone="eu-west-1b")["Subnet"]
        subnet_ids = [subnet_a["SubnetId"], subnet_b["SubnetId"]]

        # EKS cluster
        eks.create_cluster(
            name="platform-cluster",
            version="1.29",
            roleArn=role["Arn"],
            resourcesVpcConfig={"subnetIds": subnet_ids},
        )

        # Node groups
        for ng_name, desired in [("system-nodes", 2), ("workload-nodes", 3)]:
            eks.create_nodegroup(
                clusterName="platform-cluster",
                nodegroupName=ng_name,
                scalingConfig={"minSize": 1, "desiredSize": desired, "maxSize": 10},
                nodeRole=role["Arn"],
                subnets=subnet_ids,
            )

        yield eks, boto3.client("ssm", region_name="eu-west-1")


# ── suspend tests ─────────────────────────────────────────────────────────────

@mock_aws
def test_suspend_scales_nodegroups_to_zero(eks_cluster_with_nodegroups):
    eks, ssm = eks_cluster_with_nodegroups

    result = lh.suspend("platform-cluster")

    assert result["status"] == "suspended"
    assert "system-nodes" in result["suspended_nodegroups"]
    assert "workload-nodes" in result["suspended_nodegroups"]

    for ng in ["system-nodes", "workload-nodes"]:
        ng_desc = eks.describe_nodegroup(clusterName="platform-cluster", nodegroupName=ng)["nodegroup"]
        assert ng_desc["scalingConfig"]["desiredSize"] == 0
        assert ng_desc["scalingConfig"]["minSize"] == 0


@mock_aws
def test_suspend_stores_previous_sizes_in_ssm(eks_cluster_with_nodegroups):
    _, ssm = eks_cluster_with_nodegroups

    lh.suspend("platform-cluster")

    param = ssm.get_parameter(Name="/cluster-suspend/platform-cluster/workload-nodes")
    sizes = json.loads(param["Parameter"]["Value"])
    assert sizes["desiredSize"] == 3
    assert sizes["minSize"] == 1


@mock_aws
def test_suspend_skips_already_zero_nodegroups(eks_cluster_with_nodegroups):
    eks, _ = eks_cluster_with_nodegroups
    # Pre-scale system-nodes to 0
    eks.update_nodegroup_config(
        clusterName="platform-cluster",
        nodegroupName="system-nodes",
        scalingConfig={"minSize": 0, "desiredSize": 0},
    )

    result = lh.suspend("platform-cluster")

    assert "system-nodes" not in result["suspended_nodegroups"]
    assert "workload-nodes" in result["suspended_nodegroups"]


# ── resume tests ──────────────────────────────────────────────────────────────

@mock_aws
def test_resume_restores_nodegroup_sizes(eks_cluster_with_nodegroups):
    eks, _ = eks_cluster_with_nodegroups

    lh.suspend("platform-cluster")
    result = lh.resume("platform-cluster")

    assert result["status"] == "resumed"

    ng = eks.describe_nodegroup(clusterName="platform-cluster", nodegroupName="workload-nodes")["nodegroup"]
    assert ng["scalingConfig"]["desiredSize"] == 3
    assert ng["scalingConfig"]["minSize"] == 1


@mock_aws
def test_resume_without_stored_sizes_defaults_to_one(eks_cluster_with_nodegroups):
    """If SSM has no stored value (first ever resume), defaults to 1/1."""
    eks, _ = eks_cluster_with_nodegroups
    # Scale to 0 without storing — simulates manual scale-down
    eks.update_nodegroup_config(
        clusterName="platform-cluster",
        nodegroupName="system-nodes",
        scalingConfig={"minSize": 0, "desiredSize": 0},
    )

    result = lh.resume("platform-cluster")

    ng = eks.describe_nodegroup(clusterName="platform-cluster", nodegroupName="system-nodes")["nodegroup"]
    assert ng["scalingConfig"]["desiredSize"] == 1


# ── handler entrypoint tests ──────────────────────────────────────────────────

@mock_aws
def test_handler_suspend(eks_cluster_with_nodegroups):
    result = lh.handler({"action": "suspend"}, None)
    assert result["status"] == "suspended"


@mock_aws
def test_handler_resume(eks_cluster_with_nodegroups):
    lh.suspend("platform-cluster")
    result = lh.handler({"action": "resume"}, None)
    assert result["status"] == "resumed"


@mock_aws
def test_handler_unknown_action_raises():
    with pytest.raises(ValueError, match="Unknown action"):
        lh.handler({"action": "reboot"}, None)
