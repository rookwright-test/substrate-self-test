---
controls: [ra-3.1, sr-2.1, sr-6, sr-8, sa-15.3]
owner: CEO
---

# Supply chain risk assessment

Effective 2026-10-07. Updated at least every 3 months; whenever a
supplier, a GitHub Action, the Terraform provider or a container image
changes; and whenever a supplier announces a security-relevant change.

## Scope (RA-3(1) a)

Every system, component and service the environment depends on:

- AWS (the account and its us-east-2 and us-west-2 services);
- Okta (the Integrator Free Plan org);
- GitHub (repository hosting, Actions runners, secret scanning);
- Cloudflare (Workers, Containers, R2 and Access, which host
  Rookwright's demo with a copy of each run);
- the GitHub Actions the workflows use;
- the Terraform AWS and archive providers;
- the container image named in `k8s/deployment.yaml`.

## Assessment and supplier review (RA-3(1), SR-6)

Each quarterly review re-reads this table, updates it, and records
what changed.

| Supplier or component | Risk | Assessment and response |
|---|---|---|
| AWS | Platform compromise; account takeover | Accepted: the platform's own controls are relied on. Account access is limited to the Administrator. CloudTrail and Config record changes. |
| AWS organization guardrails | A service control policy limits the account to us-east-2 and us-west-2 (us-east-1 for global services) | Intended: it bounds where resources can exist. Rookwright administers the organization since 2026-10-08, so changes are deliberate. |
| Okta Integrator Free Plan | It is a developer org, not Okta's FedRAMP offering. A previous org's admin access was lost and could not be recovered. | Accepted for a self-test only. A production offering must use an identity provider authorized at Class C. Admin access is now tied to two registered devices. |
| GitHub | Repository compromise or loss of service | Branch protection that binds administrators; secret scanning and push protection; a local clone (`contingency-plan.md`) |
| Cloudflare | Exposure of the demo's copy of run data (workforce logins, IP addresses cut to /24); loss of the demo | Accepted for a demo only. Access admits a named list of people; the publishing token can write to one R2 bucket only, and the demo's token can only read it; the demo never writes back. No evidence is kept only there: the run history in AWS is the record. |
| GitHub Actions `actions/checkout`, `actions/cache` (restore and save), `actions/dependency-review-action`, `actions/setup-go`, `aws-actions/configure-aws-credentials`, `hashicorp/setup-terraform` | A version tag can be moved to different code | Each is pinned to a full commit SHA, with its version in a comment. Updating one is a reviewed change. |
| Terraform AWS provider 6.69.1 and archive provider 2.8.1 | A tampered provider binary | Provider hashes are pinned in `.terraform.lock.hcl` and checked on install |
| Container image `example/web:1.0` | Unknown provenance | Not deployed; it is a placeholder in the manifests. It must be replaced with a pinned, verified image before any deployment. |

## Criticality analysis (SA-15(3))

Rookwright develops the environment itself, so it performs the
criticality analysis.

- **When (a):**
  - before a component is added to the boundary;
  - before a supplier is replaced;
  - at each quarterly review.
- **Rigor (b):** component level. For each component, record whether
  its compromise would break:
  - integrity of the evidence substrate collects;
  - administrative access;
  - the change control on `main`.

Current result:

| Component | Integrity of evidence | Administrative access | Change control | Critical |
|---|---|---|---|---|
| GitHub repository and branch protection | Yes | No | Yes | Yes |
| Okta org | Yes (Okta evidence) | Yes | No | Yes |
| AWS account | Yes (AWS evidence) | Yes | No | Yes |
| GitHub Actions | No (CI only) | No | Yes (the required check) | Yes |
| Terraform provider | No | Yes (it applies changes) | No | Yes |
| Cloudflare (hosted demo) | No (it shows copies; the record stays in AWS) | No | No | No |
| Container image | No | No | No | No (not deployed) |

## Who carries out supply chain risk management (SR-2(1))

Rookwright is a small team, so supply chain risk management is carried
out by two roles rather than a separate team:

- **The CEO (Administrator)** leads it: keeps this document current,
  assesses and chooses suppliers and components, and responds to
  supplier notices (SR-8 below).
- **The Independent Reviewer** reviews it: approves every change to this
  document through its pull request, and signs off the yearly review of
  external services and suppliers.

This is revisited when the team grows.

## How suppliers and components are chosen (SR-5)

Before a supplier, service or software component is added or replaced:

1. **Authorization.** A service that will hold federal customer data
   must be a FedRAMP-authorized offering at the system's class. Any
   other service records its FedRAMP status, and the risk accepted if it
   has none, in the table above.
2. **Agreement.** Use the supplier's standard customer agreement, and
   confirm it includes security incident notification terms (SR-8).
   Record which agreement covers it.
3. **Criticality.** Run the criticality analysis above before adding it.
   A critical component needs a recorded response in the assessment
   table before it is used.
4. **Least access.** Give the supplier, or the credentials it uses, only
   the access it needs: read-only where possible, scoped to one
   repository or bucket.
5. **Software components.** Take them from the publisher's official
   source, pinned to a full commit SHA, image digest or lock-file hash.
   Pull requests run GitHub's dependency review. Updating a component is
   a reviewed change.
6. **Recorded and approved.** The supplier or component is added to this
   document through a pull request approved by someone other than its
   author.

## Notification of supply chain compromises (SR-8)

**Agreements.** AWS, Okta and GitHub are used under their standard
customer agreements, which include their own security incident
notification terms. Rookwright has no separately negotiated
agreements.

**Procedures.**

- Each supplier's security notices go to an email address the
  Administrator monitors.
- GitHub sends secret scanning, push protection and Dependabot alerts
  for this repository.
- On a notice of a supplier compromise, the Administrator:
  1. assesses it against the criticality table above;
  2. rotates any affected credentials;
  3. runs substrate to confirm the boundary's state;
  4. records the event and response in the next update to this
     document.
