# --- Restore validation (cp-9.1, 2026-11-02). Every restore test ended
# TIMED_OUT: nothing checked the restored copy, so a restore that
# produced an unusable database still counted as a success. Now:
#
# - Daily at 04:00 UTC, an hour before the 05:00 backup, the validator
#   writes a timestamped canary row to the database.
# - When a restore test completes, the validator checks the restored
#   copy (available, encrypted with the source's key, same engine and
#   version) and that it holds the newest canary written before its
#   recovery point, then reports SUCCESSFUL or FAILED to AWS Backup.
#
# Two functions from lambda/restore_validation (standard library only):
# the prober runs in the VPC with no AWS permissions and only speaks
# PostgreSQL, over TLS verified against AWS's RDS certificate bundle;
# the validator, outside the VPC, makes the AWS calls and is the only
# role that reads the database secret. The database gains a second
# security group admitting the prober on 5432 and nothing else; the
# original group keeps no rules. A failed invocation lands in the
# incident dead-letter queue, which substrate watches. ---

# The validator's settings are packaged as config.json rather than
# environment variables: Lambda decrypts environment variables with the
# caller's own kms:Decrypt, which the read-only drift role is denied, so
# every drift check saw them missing (2026-11-02). None is secret.
locals {
  restore_prober_name      = "substrate-restore-prober"
  restore_validation_files = ["pgwire.py", "prober.py", "validator.py", "rds-global-bundle.pem"]
}

data "archive_file" "restore_validation" {
  type        = "zip"
  output_path = "${path.module}/.terraform/restore_validation.zip"
  dynamic "source" {
    for_each = local.restore_validation_files
    content {
      content  = file("${path.module}/lambda/restore_validation/${source.value}")
      filename = source.value
    }
  }
  source {
    content = jsonencode({
      SOURCE_DB       = aws_db_instance.app.identifier
      DB_SECRET_ARN   = aws_secretsmanager_secret.db_master.arn
      PROBER_FUNCTION = local.restore_prober_name
    })
    filename = "config.json"
  }
}

resource "aws_security_group" "restore_prober" {
  name        = "substrate-self-test-restore-prober"
  description = "Restore validation prober: out to the database on 5432 only"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_egress_rule" "restore_prober_db" {
  security_group_id            = aws_security_group.restore_prober.id
  referenced_security_group_id = aws_security_group.db_validation.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_security_group" "db_validation" {
  name        = "substrate-self-test-db-validation"
  description = "Database access for the restore validation prober only (5432)"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "db_validation_prober" {
  security_group_id            = aws_security_group.db_validation.id
  referenced_security_group_id = aws_security_group.restore_prober.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_iam_role" "restore_prober" {
  name = "substrate-restore-prober"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Network interfaces in the VPC, and its own logs; nothing else.
resource "aws_iam_role_policy_attachment" "restore_prober" {
  role       = aws_iam_role.restore_prober.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_cloudwatch_log_group" "restore_prober" {
  name              = "/aws/lambda/substrate-restore-prober"
  retention_in_days = 365
}

resource "aws_lambda_function" "restore_prober" {
  function_name    = local.restore_prober_name
  description      = "Restore validation: writes and reads the database canary (in the VPC, no AWS permissions)"
  role             = aws_iam_role.restore_prober.arn
  runtime          = "python3.13"
  handler          = "prober.handler"
  filename         = data.archive_file.restore_validation.output_path
  source_code_hash = data.archive_file.restore_validation.output_base64sha256
  timeout          = 30
  memory_size      = 128
  vpc_config {
    subnet_ids         = data.aws_subnets.default.ids
    security_group_ids = [aws_security_group.restore_prober.id]
  }
  depends_on = [aws_cloudwatch_log_group.restore_prober, aws_iam_role_policy_attachment.restore_prober]
}

resource "aws_iam_role" "restore_validator" {
  name = "substrate-restore-validator"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "restore_validator" {
  name = "restore-validation"
  role = aws_iam_role.restore_validator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.restore_validator.arn}:*"
      },
      {
        Sid      = "ReadDatabases"
        Effect   = "Allow"
        Action   = "rds:DescribeDBInstances"
        Resource = "arn:aws:rds:us-east-2:${local.suffix}:db:*"
      },
      {
        # Restore jobs have no resource ARN to scope these to.
        Sid      = "RestoreJobs"
        Effect   = "Allow"
        Action   = ["backup:DescribeRestoreJob", "backup:PutRestoreValidationResult"]
        Resource = "*"
      },
      {
        Sid      = "DatabasePassword"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.db_master.arn
      },
      {
        Sid       = "DecryptThePasswordOnly"
        Effect    = "Allow"
        Action    = "kms:Decrypt"
        Resource  = aws_kms_key.app.arn
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.us-east-2.amazonaws.com" } }
      },
      {
        Sid      = "Prober"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.restore_prober.arn
      },
      {
        Sid      = "DeadLetters"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.incident_dlq.arn
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "restore_validator" {
  name              = "/aws/lambda/substrate-restore-validator"
  retention_in_days = 365
}

resource "aws_lambda_function" "restore_validator" {
  function_name    = "substrate-restore-validator"
  description      = "Restore validation: checks each restore test's copy and writes the daily canary"
  role             = aws_iam_role.restore_validator.arn
  runtime          = "python3.13"
  handler          = "validator.handler"
  filename         = data.archive_file.restore_validation.output_path
  source_code_hash = data.archive_file.restore_validation.output_base64sha256
  timeout          = 120
  memory_size      = 128
  dead_letter_config {
    target_arn = aws_sqs_queue.incident_dlq.arn
  }
  depends_on = [aws_cloudwatch_log_group.restore_validator, aws_iam_role_policy.restore_validator]
}

resource "aws_cloudwatch_event_rule" "restore_validation" {
  name        = "substrate-contingency-restore-validation"
  description = "AWS Backup restore tests that completed: validate the restored copy"
  event_pattern = jsonencode({
    source        = ["aws.backup"]
    "detail-type" = ["Restore Job State Change"]
    detail = {
      status                = ["COMPLETED"]
      restoreTestingPlanArn = [{ exists = true }]
    }
  })
}

resource "aws_cloudwatch_event_rule" "restore_canary" {
  name                = "substrate-contingency-restore-canary"
  description         = "Daily, before the backup: write the canary restore tests check for"
  schedule_expression = "cron(0 4 * * ? *)"
}

resource "aws_cloudwatch_event_target" "restore_validation" {
  rule      = aws_cloudwatch_event_rule.restore_validation.name
  target_id = "validator"
  arn       = aws_lambda_function.restore_validator.arn
  dead_letter_config {
    arn = aws_sqs_queue.incident_dlq.arn
  }
}

resource "aws_cloudwatch_event_target" "restore_canary" {
  rule      = aws_cloudwatch_event_rule.restore_canary.name
  target_id = "validator"
  arn       = aws_lambda_function.restore_validator.arn
  input     = jsonencode({ action = "write-canary" })
  dead_letter_config {
    arn = aws_sqs_queue.incident_dlq.arn
  }
}

resource "aws_lambda_permission" "restore_validation" {
  for_each = {
    validation = aws_cloudwatch_event_rule.restore_validation.arn
    canary     = aws_cloudwatch_event_rule.restore_canary.arn
  }
  statement_id  = "events-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.restore_validator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = each.value
}
