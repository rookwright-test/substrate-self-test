---
controls: [cp-2.3, cp-2.8, cp-6.3, cp-7.2]
owner: CEO
---

# Contingency plan

Effective 2026-10-07. Reviewed at least every 3 months.

## Essential functions and resumption (CP-2(3))

The environment has one essential function: being available to run
substrate against, so that collection and compilation produce evidence.

That function is resumed within **5 business days** of this plan being
activated. Activation means a disruption that stops substrate running
against the boundary: losing a component, losing access to one, or
losing the administrator's Mac.

Resumption is by rebuilding, not restoring:

1. Clone the repository from GitHub.
2. Run `terraform apply` from `main` for the AWS resources.
3. Re-issue collector credentials.
4. Run substrate, and confirm the result matches the last recorded run.

## The database: recovery objectives and testing

The database is the one component restored rather than rebuilt. Within
the 5-day resumption above, it is recovered to a known state:

- **Recovery point objective: 24 hours.** AWS Backup takes a snapshot
  every day at 05:00 UTC and keeps it 14 days.
- **Recovery time objective: 4 hours** from starting a restore to a
  usable database.

**Testing.** Every Saturday, AWS Backup restore testing restores the
newest snapshot into a throwaway database with no network access, keeps
it for an hour, and deletes it. Each test's outcome opens a GitHub issue
labelled `contingency-test`. Within 3 days the Administrator reviews it
and closes it with a comment saying what was checked, and, if the test
failed or ran slow, which corrective action was started.

**Validation.** Every day at 04:00 UTC, an hour before the backup, a
Lambda function writes a timestamped canary row to the database. When a
restore test completes, it checks the restored copy: available,
encrypted with the source's key, the same engine and version, and
holding the newest canary written before its recovery point. It reports
the test to AWS Backup as successful or failed, so a restore that
produced an unusable database can't pass.

## Critical assets (CP-2(8))

| Asset | Why it is critical | Protection |
|---|---|---|
| The GitHub repository | Source of truth for all infrastructure, manifests and these documents | Hosted by GitHub, with a full clone on the administrator's Mac. Protected `main`. |
| Okta Admin Console access | Without it the Okta component cannot be administered or re-credentialed. A previous org was lost this way. | Okta Verify FastPass on two registered devices, a Mac and an iPhone |
| AWS root and administrator credentials | Needed to rebuild AWS resources | Held by the administrator only |
| Terraform state | Maps code to live AWS resources | A versioned, encrypted S3 bucket, every previous version kept. Never in git. |
| Collector credentials | Needed to run substrate | Under `~/.substrate/` on the administrator's Mac, and as GitHub Actions secrets for the live runs. All can be re-issued from their consoles. |
| Audit records (CloudTrail bucket and CloudWatch Logs) | The environment's record of changes | Versioned, encrypted S3 with log file validation |

## Alternate storage site accessibility (CP-6(3))

The repository has two copies: GitHub, and the clone on the
administrator's Mac. In AWS, the database's automated backups are
replicated to us-west-2 and a read replica runs there, both encrypted
with a us-west-2 key. The S3 buckets, including the audit bucket, are in
us-east-2 only.

| Area-wide disruption | Accessibility problem | Mitigation |
|---|---|---|
| us-east-2 outage | The S3 buckets and audit records are unreachable. The database's backups and read replica in us-west-2 stay reachable. | Restore or promote the database in us-west-2 if needed. The buckets hold nothing that can't be regenerated; wait for the Region, or rebuild in us-west-2 from Terraform. |
| GitHub outage | The hosted repository is unreachable | Keep working from the local clone. Changes wait for GitHub to recover, because none may bypass review. |
| Loss of the administrator's Mac | The local clone, Terraform state and collector credentials are gone | Re-clone from GitHub. Re-issue credentials, signing in to Okta from the registered iPhone. Rebuild state as described above. |

## Alternate processing site accessibility (CP-7(2))

Processing happens in two places: AWS us-east-2, and wherever
substrate runs. Substrate runs in GitHub Actions after every merge to
`main` and every 6 hours, from a pinned commit. The database's alternate
processing site is its read replica in us-west-2, which can be promoted
to a standalone database. The alternate processing site for substrate
is the administrator's Mac, or any other machine with Go and the
repository; it needs no special setup.

| Area-wide disruption | Accessibility problem | Mitigation |
|---|---|---|
| us-east-2 outage | Live collection from AWS cannot run | Static compilation from the repository still runs. Live collection resumes when the Region does, or after a rebuild in us-west-2 as above. |
| Regional disruption where the administrator works (power, network) | No machine can reach the platforms | Run from any machine with network access once one is available. All credentials can be re-issued remotely. |
| Okta outage | No admin sign-in and no Okta collection | AWS and GitHub collection still run. The Okta evidence is marked undetermined until Okta recovers. |
| GitHub Actions outage | No live runs, drift checks or scheduled task issues | Run substrate from the administrator's Mac. Scheduled work resumes when Actions does; a missed run shows as a gap in the run history. |

## Coordination with incident response (CP-2(1), IR-3(2))

This plan and incident handling are coordinated by one rule: an
incident that stops substrate running against the boundary activates
this plan. Incident handling is in `continuous-monitoring.md`
("Incidents"), and PII breaches are in `incident-response-pii.md`. The
Administrator leads both, so there is one owner for the incident and
for the recovery. The incident's issue records the activation, and its
closing comment records the recovery.

The tests are coordinated too. They run on separate schedules so that
none hides another's result:

- restore test: Saturdays;
- restore validation: daily;
- incident drill: the 1st of each month;
- audit-failure drill: the 15th of each month.

The restore test and each drill open their own GitHub issue; the daily
validation reports through the restore test it checks. A failed test is
checked for what it means for the others before its issue is closed.

## Not covered by this plan

Alternate processing site agreements with priority-of-service
provisions (CP-7(3)). No such agreement exists. AWS's standard terms
include none, and a 5-day recovery time doesn't need one.
