data archive_file zip {
  type        = "zip"
  source_file = "build/aws-lambda-deregister-target-go"
  output_path = "build/aws-lambda-deregister-target-go.zip"
}

resource aws_iam_role iam_for_lambda {
  name = "${var.name_prefix}-${var.wenv}-deregister-target-fargate-spot"

  assume_role_policy = jsonencode({
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: ["sts:AssumeRole"],
        Principal: {"Service": "lambda.amazonaws.com"},
      }
    ]
  })
}

resource aws_sqs_queue deadletter_queue_for_deregister_lambda {
  name                      = "${var.name_prefix}-${var.wenv}-dead-failed-deregister"
  message_retention_seconds = 1209600
  receive_wait_time_seconds = 10
}

resource aws_iam_role_policy deregister_policy {
  name = "${var.name_prefix}-${var.wenv}-policy-deregister-target-fargate-spot"
  role = aws_iam_role.iam_for_lambda.id

  policy = jsonencode({
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: [
          "ecs:DescribeServices",
          "elasticloadbalancing:DeregisterTargets",
          "ec2:DescribeSubnets"
        ],
        Resource: "*"
      },
      {
        Effect: "Allow",
        Action: [
          "ec2:DescribeNetworkInterfaces",
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeInstances",
          "ec2:AttachNetworkInterface"
        ],
        Resource: "*"
      },
      {
        Effect: "Allow",
        Action: [ "sqs:SendMessage" ],
        Resource: aws_sqs_queue.deadletter_queue_for_deregister_lambda.arn
      }
    ]
  })
}

resource aws_cloudwatch_event_rule fargate_spot_rule {
  name        = "${var.name_prefix}-${var.wenv}-deregister-targets-fargate-spot-rule"
  description = "Capture Fargate Spot tasks that are going to be shutdown."

  event_pattern = <<EOF
{
  "source": ["aws.ecs"],
  "detail-type": ["ECS Task State Change"],
  "detail": {
    "clusterArn": ["${var.cluster_arn}"],
    "stoppedReason": ["Your Spot Task was interrupted."]
  }
}
EOF
}

resource aws_lambda_function lambda_deregister_targets_fargate_spot {
  function_name    = "${var.name_prefix}-${var.wenv}-deregister-targets-fargate-spot"
  filename         = "build/aws-lambda-deregister-target-go.zip"
  handler          = "${path.module}/script.go"
  source_code_hash = data.archive_file.zip.output_base64sha256
  role             = aws_iam_role.iam_for_lambda.arn
  runtime          = "go1.x"
  memory_size      = 128
  timeout          = 10

  dead_letter_config {
    target_arn = aws_sqs_queue.deadletter_queue_for_deregister_lambda.arn
  }
}

resource aws_lambda_permission allow_cloudwatch_to_call_deregister_lambda {
  statement_id = "AllowExecutionFromCloudWatch"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_deregister_targets_fargate_spot.function_name
  principal = "events.amazonaws.com"
  source_arn = aws_cloudwatch_event_rule.fargate_spot_rule.arn
}

resource aws_cloudwatch_event_target rule_target_lambda_deregister {
  rule = aws_cloudwatch_event_rule.fargate_spot_rule.name
  target_id = "${var.name_prefix}-${var.wenv}-lambda-deregister-target-go"
  arn = aws_lambda_function.lambda_deregister_targets_fargate_spot.arn
}
