data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Resolves an assumed-role session to its role ARN, which is what a trust policy can name.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  arn_prefix = "arn:${local.partition}:sagemaker:${var.region}:${local.account_id}"
  endpoint_arn = "${local.arn_prefix}:endpoint/${lower(local.endpoint_name)}"
  ic_arn       = var.inference_components ? "${local.arn_prefix}:inference-component/${lower(local.ic_name)}" : null
  role_base    = trim(substr(local.endpoint_name, 0, 50), "-")

  invoke_principals = var.invoke_principal_arns != null ? var.invoke_principal_arns : [data.aws_iam_session_context.current.issuer_arn]
  weights_buckets = compact([
    local.js_enabled ? local.js_bucket : "",
    local.js_enabled ? "jumpstart-private-cache-prod-${var.region}" : "",
    var.model_data_url != null ? regex("^s3://([^/]+)", var.model_data_url)[0] : "",
  ])

  # What the bearer-token (openai) and SigV4 (invocations) paths need; the same policy goes on the optional CI user.
  invoke_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sagemaker:InvokeEndpoint", "sagemaker:InvokeEndpointWithResponseStream"]
        Resource = compact([local.endpoint_arn, local.ic_arn])
      },
      {
        # Bearer tokens for /openai/v1; the action takes no resource-level restriction.
        Effect   = "Allow"
        Action   = "sagemaker:CallWithBearerToken"
        Resource = "*"
      },
    ]
  })
}

# --- Execution role: what the endpoint's containers run as ---

resource "aws_iam_role" "execution" {
  name = "${local.role_base}-exec"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "sagemaker.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "execution" {
  name = "pull-images-write-logs-read-weights"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
          Resource = "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/sagemaker/*"
        },
        {
          Effect   = "Allow"
          Action   = "cloudwatch:PutMetricData"
          Resource = "*"
        },
      ],
      length(local.weights_buckets) == 0 ? [] : [{
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = flatten([for b in local.weights_buckets : ["arn:${local.partition}:s3:::${b}", "arn:${local.partition}:s3:::${b}/*"]])
      }],
    )
  })
}

resource "time_sleep" "iam_propagation" {
  create_duration = "15s"
  triggers        = { role = aws_iam_role.execution.arn, policy = aws_iam_role_policy.execution.policy }
}

# --- Invoke role: what Bifrost (or probe.py) assumes to call the endpoint ---

resource "aws_iam_role" "invoke" {
  name = "${local.role_base}-invoke"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { AWS = local.invoke_principals }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "invoke" {
  name   = "invoke-endpoint"
  role   = aws_iam_role.invoke.id
  policy = local.invoke_policy
}

# --- Optional CI user (secret lands in state) ---

resource "aws_iam_user" "ci" {
  count = var.create_access_key ? 1 : 0
  name  = "${local.role_base}-ci"
}

resource "aws_iam_user_policy" "ci" {
  count  = var.create_access_key ? 1 : 0
  name   = "invoke-endpoint"
  user   = aws_iam_user.ci[0].name
  policy = local.invoke_policy
}

resource "aws_iam_access_key" "ci" {
  count = var.create_access_key ? 1 : 0
  user  = aws_iam_user.ci[0].name
}
