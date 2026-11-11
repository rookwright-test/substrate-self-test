---
controls: [ac-5]
owner: CEO
---

# Separation of duties

Effective 2026-10-07. Reviewed at least every 3 months. Last changed
2026-10-07: AWS collection moved to a read-only role.

## Duties (AC-5 a)

| Role | Duties |
|---|---|
| Administrator (the CEO) | Administers the AWS account, the Okta org and the GitHub repository. Authors changes to infrastructure code and to these documents. Runs substrate. |
| Independent Reviewer | Reviews and approves pull requests to `main`, including every change to these documents. Holds no administrative access to any component. |
| Collector identities (machine) | Read configuration and logs so substrate can produce evidence. Never change anything they assess. |

The duty that must stay separated is **authoring a change** versus
**approving it**. Nobody approves their own change.

## Access authorizations (AC-5 b)

**GitHub.**

- The Administrator is the repository owner.
- The Independent Reviewer is a collaborator who can review and
  approve, and cannot change branch protection.
- Branch protection on `main` requires one approving review from
  someone other than the author, dismisses stale approvals, and applies
  to administrators.
- The substrate collector uses a fine-grained token limited to this
  repository, with read-only permissions.

**Okta.**

- The Administrator is the org's super administrator, signing in to
  the Admin Console with phishing-resistant authentication from a
  registered device.
- The substrate collector app holds the Read-Only Administrator role
  and read-only API scopes.

**AWS.**

- The Administrator holds administrative access for Terraform changes,
  through the IAM group `substrate-admins` rather than a policy attached
  to their user (Security Hub IAM.2, #116).
- Substrate collection uses the IAM role `substrate-collector`, which
  holds only substrate's published read-only policy (copied in this
  repository as `substrate-readonly-policy.json`). Only the
  Administrator's IAM user can assume it, and it has no long-lived
  keys.
- The drift check, every 6 hours, uses the IAM role `substrate-drift-check`,
  which only this repository's workflows running on `main` can assume
  (GitHub OIDC, no stored keys). It reads configuration across the
  account but no S3 object except the Terraform state, and no secret
  value.
- Terraform state is kept in a versioned, encrypted S3 bucket that
  refuses non-TLS requests.
- After every merge to `main`, and every 6 hours, a GitHub Actions job
  runs substrate against the live system (cm-4.2). It reaches AWS
  through the read-only `substrate-collector` role by OIDC, from `main`
  only, and holds the Okta collector app's key and the read-only GitHub
  token as Actions secrets, which pull requests from forks never
  receive. Substrate's source is read with a read-only deploy key.
- The same job keeps each run's compiled output as the IAM role
  `substrate-history-writer`, which can only add objects to the
  run-history bucket (OIDC, `main` only).
- It also copies each run to the hosted demo's Cloudflare R2 bucket
  with an R2 token that can write to that one bucket only, held as
  Actions secrets. The demo reads the bucket with a separate read-only
  token and admits only a named list of people through Cloudflare
  Access.
- The control register's scheduler (every 6 hours) opens task issues
  with the workflow's own GitHub token and reads the Okta System Log
  with the collector app's key, read-only.

## Known deviations

**Resolved: AWS collection used an administrative identity.** Until
the `substrate-collector` role was created, collection ran as the
Administrator's IAM user, which holds `AdministratorAccess`. Collection
now assumes the read-only role. The Administrator's user keeps
administrative access for Terraform.

**Accepted: an AWS-managed administrative role.** The account holds
`AccountFullAccessRole` (path `/managed/`), which AWS created with
`AdministratorAccess` for its account management service. AWS manages it,
the organization's service control policy protects it from change, and
deleting it was refused. It was reviewed on 2026-11-10 and kept.

**Bypassing branch protection.** The Administrator can temporarily
disable "applies to administrators" in the repository settings. That is
permitted only to land a change no one else is able to approve, and
must be re-enabled immediately afterwards. Each use is recorded in
substrate's `docs/REQUIREMENTS.md` with its date and reason.
