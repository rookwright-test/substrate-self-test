---
controls: [pl-8, pl-10, pm-7, ac-14]
owner: CEO
---

# Security plan: substrate self-test environment

Effective 2026-10-07. Reviewed at least every 3 months, and whenever a
component is added to or removed from the boundary. A change to this
document takes effect only when merged to `main` through an approved
pull request.

## Purpose and scope

The self-test environment exists so Rookwright can run substrate
against real infrastructure it owns. It serves no customers, holds no
customer or federal data, and is not offered to anyone. Its boundary is
declared in `substrate-boundary.yaml`:

| Component | What it is |
|---|---|
| AWS account, us-east-2 | Five S3 buckets and the other data stores listed under "Where data is stored", two KMS keys (one for the application, one for the audit logs), a multi-Region CloudTrail trail with CloudWatch Logs, an AWS Config recorder and one managed rule, Resolver DNSSEC validation on the default VPC, VPC Block Public Access blocking internet gateway traffic both ways, an encrypted EBS volume, an encrypted PostgreSQL instance that holds no data and has no network access, AWS Backup (daily, for the database), two Lambda functions that check each restore test (the restore prober and validator), EventBridge rules and an SQS dead-letter queue for incident issues, GuardDuty with malware protection, Security Hub, Inspector and Macie |
| AWS account, us-west-2 | The database's replicated automated backups and an encrypted read replica, with their own KMS key and a security group with no rules; VPC Block Public Access as in us-east-2; GuardDuty, Security Hub, Inspector and an AWS Config recorder |
| Every other AWS Region | Nothing. The organization's service control policy denies their use. |
| Okta org | Workforce identity for the administrator and the substrate collector app |
| GitHub repository `rookwright-test/substrate-self-test` | Infrastructure code, Kubernetes manifests, CI, and these documents |

The Kubernetes manifests in `k8s/` (a Deployment, NetworkPolicy, Secret
and ConfigMap) are **outside the boundary** because they have never been
deployed to a cluster. They return to the boundary, and to this table,
in the same pull request that deploys them.

## Where data is stored (CM-12)

Every place the environment stores data, by Region. The yearly review
of functions, software and data location checks this list against the
account, and a pull request that adds or removes a data store updates it.

| Data | Where | Region | Kept for |
|---|---|---|---|
| Application data (empty; for test data only) | S3 `substrate-self-test-app-data-632839731153` | us-east-2 | 365 days; old versions 30 days |
| Nothing; the bucket substrate's gate is tested against (empty) | S3 `substrate-self-test-app-logs-632839731153` | us-east-2 | 365 days |
| CloudTrail logs and AWS Config snapshots | S3 `substrate-self-test-audit-632839731153` | us-east-2 | 365 days; old versions 30 days |
| CloudTrail events, for queries and alarms | CloudWatch Logs `/substrate-self-test/cloudtrail` | us-east-2 | 30 days |
| Okta System Log archive | CloudWatch Logs `/aws/events/okta-system-log` | us-east-2 | 365 days |
| Restore check logs | CloudWatch Logs `/aws/lambda/substrate-restore-prober` and `/aws/lambda/substrate-restore-validator` | us-east-2 | 365 days |
| Substrate's compiled run history | S3 `substrate-self-test-run-history-632839731153` | us-east-2 | 365 days; old versions 30 days |
| Terraform state | S3 `substrate-self-test-tfstate-632839731153` (versioned) | us-east-2 | Until replaced; every version kept |
| Database (holds no data) | RDS `substrate-self-test` | us-east-2 | Automated backups 7 days |
| Database backups | AWS Backup vault `substrate-self-test` | us-east-2 | 14 days |
| Database read replica and replicated backups | RDS `substrate-self-test-replica` | us-west-2 | Backups 7 days |
| Database master password | Secrets Manager `substrate-self-test/db-master` | us-east-2 | The current value only |
| Incident issues EventBridge couldn't open | SQS `substrate-incident-issues-dlq` | us-east-2 | 14 days |
| A copy of each live run for Rookwright's hosted demo (review packets with IP addresses cut to /24; never the full packet) | Cloudflare R2 `rookwright-demo-runs` | Cloudflare, Eastern North America (ENAM) | 365 days (bucket lifecycle rule) |

The encrypted EBS volume is unattached and stores nothing the
environment uses.

## Resources for security (PM-3, SA-2)

The plans in these documents assume people's time and some spending:
the reviews and drill acknowledgements, the weekly audit log review,
the yearly reviews, and the AWS, Okta and Cloudflare services.

- **Time:** [the hours each week the Administrator and the Independent
  Reviewer commit to security work]
- **Budget:** [what is budgeted each year for security services and
  tools, and who approves spending]
- **Open spending decisions:** AWS Shield Advanced (sc-5) is not
  enabled. [Decision and reason]

## Control baseline (PL-10)

The selected baseline is FedRAMP 20x Class C under the Consolidated
Rules for 2026 (CR26), as expressed by its Key Security Indicators.
Class C is the class Rookwright's Phase 1 work targets. The environment
does not claim to meet the baseline; substrate's output reports how
much of it is verified.

## Security architecture (PL-8)

**Confidentiality.**

- S3 buckets block all public access and refuse non-TLS requests.
- `app_data` and the PostgreSQL instance are encrypted with a
  customer-managed KMS key that rotates automatically. The database's
  master password is generated and held by AWS Secrets Manager.
- The database has no public address and its security group allows no
  traffic.
- Administrator sign-in to the Okta Admin Console requires
  phishing-resistant authentication (Okta FastPass) from a registered
  device.

**Integrity.**

- Changes to `main` require a pull request, an approving review from
  someone other than the author, and a passing `test` check. The rule
  applies to administrators.
- CloudTrail records management events, with log file validation on.
- AWS Config records resource configuration changes.
- Resolver DNSSEC validation is on for the default VPC.
- Container manifests run as non-root, with a read-only root
  filesystem, no privilege escalation, all capabilities dropped, and a
  default-deny NetworkPolicy.

**Availability.** Availability is not a requirement of this
environment beyond what `contingency-plan.md` states. The database has
replicated backups and a read replica in us-west-2; everything else is
rebuilt from Terraform, not restored.

**Personally identifiable information.** The environment processes no
PII beyond workforce identity data: the names and email addresses of
its Okta and GitHub accounts. Substrate hashes GitHub author identities
before recording them. Adding any other PII requires updating this
plan first.

**External dependencies and assumptions.**

- AWS, Okta and GitHub operate the underlying platforms. Their own
  controls are assumed, not verified. `supply-chain-risk.md` assesses
  them.
- The AWS account is a member of Rookwright's own AWS organization. A
  service control policy limits it to us-east-2 (home) and us-west-2
  (second site), with us-east-1 for global services only.
- The administrator's Mac holds the Terraform state and the collector
  credentials. `contingency-plan.md` covers its loss.

## Enterprise architecture (PM-7)

Rookwright's enterprise is small: this environment, the private
`rookwright/substrate` source repository, and the public rookwright.com
website with its security.txt. Information security is considered at
the enterprise level in two ways:

- the product's own source never runs in, or depends on, the
  self-test environment;
- identities are separate per system, with no shared credentials
  between the self-test environment and anything else.

Risk to individuals, other organizations and the Nation is limited
because no customer or federal data exists anywhere in the enterprise.
This section is maintained alongside the architecture above and
revised in the same pull request as any change to it.

## Actions permitted without identification or authentication (AC-14)

| Action | Rationale |
|---|---|
| Reading the public GitHub repository and its CI results | Deliberately public: GitHub Free provides branch protection and secret scanning only on public repositories. Nothing in it is secret. |
| Loading the Okta sign-in page | Required for anyone to begin authenticating. It grants no access. |
| Reading rookwright.com and its security.txt | Public by design, so researchers can report vulnerabilities. |

No other action on any component can be performed without
identification and authentication.

## Keeping this plan current

Planned architecture changes are written into this plan, and into
`contingency-plan.md` and `supply-chain-risk.md` where they apply, in
the same pull request that makes the change.
