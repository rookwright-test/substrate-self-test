# --- Security monitoring in the second site, us-west-2 (substrate ADR
# 0028). The database replica, its key and the replicated backups live
# there, so the per-Region services us-east-2 runs must run there too:
# GuardDuty (si-3, si-4, au-6), Security Hub (ca-7), Inspector (ra-5,
# si-2.2) and Resolver DNSSEC validation (sc-21). Macie isn't: it scans
# S3, and every bucket is in us-east-2.

resource "aws_guardduty_detector" "west" {
  provider = aws.west
  enable   = true
}

resource "aws_guardduty_detector_feature" "west_ebs_malware_protection" {
  provider    = aws.west
  detector_id = aws_guardduty_detector.west.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "ENABLED"
}

resource "aws_securityhub_account" "west" {
  provider                 = aws.west
  enable_default_standards = true
  depends_on               = [aws_config_configuration_recorder_status.west]
}

# Lambda scanning here too, matching us-east-2: no functions run in
# us-west-2 today, so it costs nothing until one does.
resource "aws_inspector2_enabler" "west" {
  provider       = aws.west
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2", "ECR", "LAMBDA"]
}

resource "aws_route53_resolver_dnssec_config" "default_vpc_west" {
  provider    = aws.west
  resource_id = data.aws_vpc.default_west.id
}

# us-west-2's GuardDuty findings go to us-east-2's default event bus,
# where the incident rules (incidents.tf) open their issues: one
# pipeline, and one place substrate checks every finding reached an
# issue (ir-5, ir-4.1, si-4.5).
resource "aws_cloudwatch_event_rule" "west_guardduty_forward" {
  provider    = aws.west
  name        = "substrate-forward-guardduty-to-us-east-2"
  description = "GuardDuty findings in us-west-2, to the incident pipeline in us-east-2"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
  })
}

resource "aws_iam_role" "west_guardduty_forward" {
  name = "substrate-forward-guardduty"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "west_guardduty_forward" {
  name = "put-events-us-east-2"
  role = aws_iam_role.west_guardduty_forward.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = "arn:aws:events:us-east-2:${data.aws_caller_identity.current.account_id}:event-bus/default"
    }]
  })
}

resource "aws_cloudwatch_event_target" "west_guardduty_forward" {
  provider  = aws.west
  rule      = aws_cloudwatch_event_rule.west_guardduty_forward.name
  target_id = "us-east-2-default-bus"
  arn       = "arn:aws:events:us-east-2:${data.aws_caller_identity.current.account_id}:event-bus/default"
  role_arn  = aws_iam_role.west_guardduty_forward.arn
}

# RDS.46, risk accepted (founder, 2026-11-23; review by 2027-05-01).
# Security Hub fails both databases because they sit in the default
# VPC's public subnets. Neither is publicly accessible
# (publicly_accessible = false), and VPC Block Public Access blocks
# inbound and outbound traffic in both Regions (#118), so there is no
# way in from the internet. Moving them to private subnets means
# replacing both, with downtime and the backup and restore-test
# evidence that follows them: planned for later, not before the demo.
# A rule applies only in its own Region (AWS's automation rules
# documentation), so each Region has one.
resource "aws_securityhub_automation_rule" "rds_46_accepted_west" {
  provider    = aws.west
  rule_name   = "RDS.46 risk accepted until 2027-05-01"
  description = "The database is in the default VPC's public subnets but isn't publicly accessible, and VPC Block Public Access blocks inbound traffic. Accepted by kernwill on 2026-11-23; review by 2027-05-01."
  rule_order  = 2
  rule_status = "ENABLED"

  criteria {
    compliance_security_control_id {
      comparison = "EQUALS"
      value      = "RDS.46"
    }
    resource_id {
      comparison = "EQUALS"
      value      = aws_db_instance.app_replica.arn
    }
  }

  actions {
    type = "FINDING_FIELDS_UPDATE"
    finding_fields_update {
      workflow {
        status = "SUPPRESSED"
      }
      note {
        text       = "RDS.46 risk accepted by kernwill on 2026-11-23, review by 2027-05-01: not publicly accessible, and VPC Block Public Access blocks inbound traffic. See west.tf."
        updated_by = "terraform"
      }
    }
  }

  depends_on = [aws_securityhub_account.west]
}
