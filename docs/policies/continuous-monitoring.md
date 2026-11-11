---
controls: [ca-7.4]
owner: CEO
---

# Continuous monitoring strategy

Effective 2026-10-07. Reviewed at least every 3 months.

## When monitoring runs

Substrate is run against the whole boundary (`collect`, then `compile`):

- on every pull request, against the declared configuration, as a
  required check;
- after every merge to `main` and every 6 hours, against the live
  system, in GitHub Actions;
- whenever a supplier announces a security-relevant change.

Each live run's compiled output is kept for a year in the run-history
bucket and shown on substrate's dashboard, so results can be compared
over time.

## Risk monitoring (CA-7(4))

Risk monitoring is part of this strategy in three forms.

**Effectiveness monitoring (a).** `substrate collect` observes the live
configuration of AWS, Okta and GitHub. Observed evidence is compared
with the declared configuration in Terraform, so a control that is
declared but not in effect is visible.

**Compliance monitoring (b).** `substrate compile` evaluates the
evidence against FedRAMP 20x Class C. It reports each indicator as
satisfied, not satisfied, undetermined or not applicable, and the share
of cited controls that are verified. Any indicator that moves to "not
satisfied" is treated as a finding and fixed or explained in the next
pull request.

**Change monitoring (c).**

- Every change to the environment's code is a reviewed pull request on
  `main`.
- CloudTrail records management events in the AWS account, and reads,
  deletes and permission changes on the audit bucket.
- AWS Config records resource configuration changes.
- Okta's System Log records administrative changes, which substrate
  collects and which is archived in CloudWatch Logs for a year.
- Comparing successive substrate runs shows what changed between them.
- Every 6 hours, a GitHub Actions job compares the live AWS account
  with `main` (`terraform plan`, read-only) and looks for AWS resources
  nothing declared. Any difference opens an issue labelled `drift` and
  `incident`.
- Inspector scans for vulnerabilities, including the Lambda functions.

**Reviews people do.** The control register (`substrate-controls.yaml`)
opens an issue for each recurring review when it falls due, assigned to
its owner, every 6 hours as needed. Among them is the weekly audit log
review: CloudTrail, the Okta System Log, GuardDuty and Security Hub's
newly failed controls, which substrate gathers into a review packet. A
review counts only when someone the register allows to sign off closes
its issue with a comment, in time.

## Incidents

Every new GuardDuty finding of Medium severity or above, any attempt to
stop or delete CloudTrail logging, and 24 hours with no event in the
archived Okta System Log, opens a GitHub issue in this repository
automatically. The issue is labelled `incident` and
assigned to the Administrator, and GitHub notifies them. The issue is
the incident's record: it is worked and closed with a comment saying
what was done. GuardDuty sample findings from drills open issues
labelled `drill` too, and are never counted as real incidents.

**Incident drill.** On the first of every month a GitHub Actions job
creates a GuardDuty sample finding. Its `[DRILL]` issue must appear
within 15 minutes, and the Administrator acknowledges it within 3 days
by closing it with a comment saying the alert was received and what
would have been done. A missing issue fails the job; an unacknowledged
drill is a failed drill.

**Audit-failure drill.** On the 15th of every month a GitHub Actions job
sets the Okta log-silence alarm to ALARM with a reason starting "Drill".
Its `[DRILL]` issue must appear within 15 minutes, and is acknowledged
the same way.
