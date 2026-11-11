# Follow-ups from the weekly audit log review #113.

# --- #116, Security Hub IAM.2: no IAM policies attached to users ---
#
# substrate-admin (created by hand at account setup, not managed here)
# had AdministratorAccess attached directly. It gets it through this
# group instead. substrate's IAM collector resolves group membership
# (GetAccountAuthorizationDetails), so the user is still counted as an
# administrator in the evidence.
#
# After this is applied and the group membership is confirmed, the
# direct attachment is removed by hand (it was never in Terraform):
#   aws iam detach-user-policy --user-name substrate-admin \
#     --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
# Apply first, detach second, so the user is never without access.

resource "aws_iam_group" "admins" {
  name = "substrate-admins"
}

resource "aws_iam_group_policy_attachment" "admins" {
  group      = aws_iam_group.admins.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Non-exclusive: adds substrate-admin to this group without touching
# any other membership.
resource "aws_iam_user_group_membership" "substrate_admin" {
  user   = "substrate-admin"
  groups = [aws_iam_group.admins.name]
}

# --- #117, Security Hub EC2.172: VPC Block Public Access ---
#
# Nothing in either Region uses an internet gateway: the databases
# aren't publicly accessible, the restore prober's only egress is the
# database on 5432, and no network interface has a public IP (checked
# 2026-11-11). Blocking internet gateway traffic both ways makes that a
# guarantee rather than an accident. Add an exclusion here if something
# ever needs the internet.

resource "aws_vpc_block_public_access_options" "east" {
  internet_gateway_block_mode = "block-bidirectional"
}

resource "aws_vpc_block_public_access_options" "west" {
  provider                    = aws.west
  internet_gateway_block_mode = "block-bidirectional"
}
