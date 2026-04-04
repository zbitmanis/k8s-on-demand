# ── suspend-lambda module ──────────────────────────────────────────────────────
# Provisions the cluster suspend/resume Lambda and the EventBridge rules that
# trigger it on a schedule (hard-suspend path — no drain, no in-cluster step).
#
# The graceful suspend path (drain + notify) goes through Argo Events →
# Argo Workflow → this Lambda via boto3.  Both paths share the same function.

locals {
  function_name = "${var.cluster_name}-cluster-suspend"
  ssm_prefix    = "/cluster-suspend/${var.cluster_name}"
}

# ── Lambda deployment package ─────────────────────────────────────────────────

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../../scripts/suspend"
  output_path = "${path.module}/.build/suspend_lambda.zip"
  excludes    = ["tests", "__pycache__", "*.pyc"]
}

# ── IAM role for the Lambda ───────────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "suspend_lambda" {
  name               = "${local.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "suspend_lambda_policy" {
  # EKS — read cluster and manage node group scaling
  statement {
    sid    = "EKSNodeGroupScaling"
    effect = "Allow"
    actions = [
      "eks:ListNodegroups",
      "eks:DescribeNodegroup",
      "eks:UpdateNodegroupConfig",
      "eks:TagResource",
      "eks:UntagResource",
    ]
    resources = [
      "arn:aws:eks:${var.aws_region}:${var.aws_account_id}:cluster/${var.cluster_name}",
      "arn:aws:eks:${var.aws_region}:${var.aws_account_id}:nodegroup/${var.cluster_name}/*/*",
    ]
  }

  # SSM — persist node group sizes
  statement {
    sid    = "SSMSuspendState"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:DeleteParameter",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter${local.ssm_prefix}/*",
    ]
  }

  # CloudWatch Logs — Lambda execution logs
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/${local.function_name}:*",
    ]
  }
}

resource "aws_iam_policy" "suspend_lambda" {
  name   = "${local.function_name}-policy"
  policy = data.aws_iam_policy_document.suspend_lambda_policy.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "suspend_lambda" {
  role       = aws_iam_role.suspend_lambda.name
  policy_arn = aws_iam_policy.suspend_lambda.arn
}

# ── Lambda function ────────────────────────────────────────────────────────────

resource "aws_lambda_function" "cluster_suspend" {
  function_name    = local.function_name
  description      = "Suspend and resume EKS node groups for cost saving"
  role             = aws_iam_role.suspend_lambda.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "lambda_handler.handler"
  runtime          = "python3.12"
  timeout          = 300   # 5 min — resume wait can take a few minutes
  memory_size      = 128

  environment {
    variables = {
      CLUSTER_NAME           = var.cluster_name
      SSM_PREFIX             = local.ssm_prefix
      WAIT_FOR_NODES         = tostring(var.wait_for_nodes_on_resume)
      NODE_READY_TIMEOUT_SEC = tostring(var.node_ready_timeout_sec)
    }
  }

  tags = merge(var.tags, {
    "platform.io/component" = "cluster-suspend"
    "platform.io/managed-by" = "terraform"
  })
}

resource "aws_cloudwatch_log_group" "cluster_suspend" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 30
  tags              = var.tags
}

# ── EventBridge rules (hard-suspend schedule) ─────────────────────────────────

resource "aws_cloudwatch_event_rule" "suspend_schedule" {
  count               = var.enable_schedule ? 1 : 0
  name                = "${local.function_name}-suspend"
  description         = "Suspend EKS cluster at end of business day"
  schedule_expression = var.suspend_schedule_cron
  tags                = var.tags
}

resource "aws_cloudwatch_event_rule" "resume_schedule" {
  count               = var.enable_schedule ? 1 : 0
  name                = "${local.function_name}-resume"
  description         = "Resume EKS cluster at start of business day"
  schedule_expression = var.resume_schedule_cron
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "suspend" {
  count     = var.enable_schedule ? 1 : 0
  rule      = aws_cloudwatch_event_rule.suspend_schedule[0].name
  target_id = "cluster-suspend"
  arn       = aws_lambda_function.cluster_suspend.arn
  input     = jsonencode({ action = "suspend" })
}

resource "aws_cloudwatch_event_target" "resume" {
  count     = var.enable_schedule ? 1 : 0
  rule      = aws_cloudwatch_event_rule.resume_schedule[0].name
  target_id = "cluster-resume"
  arn       = aws_lambda_function.cluster_suspend.arn
  input     = jsonencode({ action = "resume" })
}

resource "aws_lambda_permission" "allow_suspend_eventbridge" {
  count         = var.enable_schedule ? 1 : 0
  statement_id  = "AllowEventBridgeSuspend"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cluster_suspend.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.suspend_schedule[0].arn
}

resource "aws_lambda_permission" "allow_resume_eventbridge" {
  count         = var.enable_schedule ? 1 : 0
  statement_id  = "AllowEventBridgeResume"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cluster_suspend.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.resume_schedule[0].arn
}

# ── Allow Argo Workflow IAM role to invoke the Lambda ─────────────────────────
# The Argo Workflow runner invokes Lambda via boto3 in the invoke-suspend-lambda
# template.  Its IRSA role needs lambda:InvokeFunction on this function.

data "aws_iam_policy_document" "argo_invoke_suspend" {
  statement {
    sid     = "InvokeSuspendLambda"
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.cluster_suspend.arn]
  }
}

resource "aws_iam_policy" "argo_invoke_suspend" {
  name   = "${local.function_name}-argo-invoke"
  policy = data.aws_iam_policy_document.argo_invoke_suspend.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "argo_invoke_suspend" {
  role       = var.argo_workflow_iam_role_name
  policy_arn = aws_iam_policy.argo_invoke_suspend.arn
}
