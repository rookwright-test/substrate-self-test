# Run history (2026-11-04, the founder chose a private bucket): each
# post-merge live run's compiled output is kept here, so substrate's UI
# can show the live system over time, not only its latest state.
# Substrate never writes anywhere; the workflow does, as its own role,
# never the collector's.
#
# A security bucket (substrate-parameters.yaml, non_privileged_use):
# compliance results describe the system's security posture, so the
# administrator reading them is security work for ac-6.2. The writer
# role holds no action on a declared security service, so it isn't a
# security-access holder (ac-6.1) and isn't declared as one.

resource "aws_s3_bucket" "run_history" {
  bucket = "substrate-self-test-run-history-${local.suffix}"
}

resource "aws_s3_bucket_versioning" "run_history" {
  bucket = aws_s3_bucket.run_history.id
  versioning_configuration { status = "Enabled" }
}

# sc-13: KMS (AWS's managed aws/s3 key), like the other buckets.
resource "aws_s3_bucket_server_side_encryption_configuration" "run_history" {
  bucket = aws_s3_bucket.run_history.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
  }
}

resource "aws_s3_bucket_public_access_block" "run_history" {
  bucket                  = aws_s3_bucket.run_history.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# sc-8: TLS only.
resource "aws_s3_bucket_policy" "run_history" {
  bucket = aws_s3_bucket.run_history.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.run_history.arn, "${aws_s3_bucket.run_history.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.run_history]
}

# si-12.3: disposed of after the same year as everything else.
resource "aws_s3_bucket_lifecycle_configuration" "run_history" {
  bucket = aws_s3_bucket.run_history.id
  rule {
    id     = "dispose-after-retention"
    status = "Enabled"
    filter {}
    expiration {
      days = local.retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = local.noncurrent_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# The writer: this repository's workflows on main only, by GitHub OIDC
# (subject as in drift.tf). It can add objects under runs/ and nothing
# else: no read, no delete, no other bucket.
resource "aws_iam_role" "history_writer" {
  name = "substrate-history-writer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_main_subjects
        }
      }
    }]
  })
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "history_writer" {
  name = "write-run-history"
  role = aws_iam_role.history_writer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AddRunOutputs"
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = ["${aws_s3_bucket.run_history.arn}/runs/*"]
    }]
  })
}
