# Self-teardown that fires even if the machine that ran apply is offline: one-shot EventBridge Scheduler at() schedules call
# DeleteInferenceComponent and then DeleteEndpoint. The deadline is re-armed to now + N on every apply, so re-applying
# extends it (and every plan shows the schedules changing). Models and endpoint configs cost nothing and stay until destroy.
locals {
  teardown_enabled = var.teardown_after_minutes > 0
  teardown_at      = local.teardown_enabled ? timeadd(plantimestamp(), "${var.teardown_after_minutes}m") : null
  endpoint_teardown_at = local.teardown_enabled ? timeadd(local.teardown_at, var.inference_components ? "5m" : "0m") : null
  schedule_base        = trim(substr(local.endpoint_name, 0, 50), "-")
}

resource "aws_iam_role" "teardown" {
  count = local.teardown_enabled ? 1 : 0
  name  = "${local.role_base}-teardown"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "teardown" {
  count = local.teardown_enabled ? 1 : 0
  name  = "delete-endpoint"
  role  = aws_iam_role.teardown[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sagemaker:DeleteEndpoint", "sagemaker:DeleteInferenceComponent"]
      Resource = compact([local.endpoint_arn, local.ic_arn])
    }]
  })
}

resource "aws_scheduler_schedule" "delete_inference_component" {
  count                   = local.teardown_enabled && var.inference_components ? 1 : 0
  name                    = "${local.schedule_base}-ic-teardown"
  schedule_expression     = "at(${formatdate("YYYY-MM-DD'T'hh:mm:ss", local.teardown_at)})"
  action_after_completion = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${local.partition}:scheduler:::aws-sdk:sagemaker:deleteInferenceComponent"
    role_arn = aws_iam_role.teardown[0].arn
    input    = jsonencode({ InferenceComponentName = local.ic_name })
  }

  depends_on = [aws_iam_role_policy.teardown]
}

resource "aws_scheduler_schedule" "delete_endpoint" {
  count                   = local.teardown_enabled ? 1 : 0
  name                    = "${local.schedule_base}-teardown"
  schedule_expression     = "at(${formatdate("YYYY-MM-DD'T'hh:mm:ss", local.endpoint_teardown_at)})"
  action_after_completion = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${local.partition}:scheduler:::aws-sdk:sagemaker:deleteEndpoint"
    role_arn = aws_iam_role.teardown[0].arn
    input    = jsonencode({ EndpointName = local.endpoint_name })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 10
    }
  }

  depends_on = [aws_iam_role_policy.teardown]
}
