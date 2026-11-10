# Briefing: spotting and avoiding counterfeit components (SR-11(1))

Internal training for everyone with access to the system: the Administrator and the Independent Reviewer. It takes about 15 minutes. Read it once a year as part of the yearly security training (task `security-training`), then record in your training issue that you completed it, with the date.

## Why this applies to us

A counterfeit component is hardware, software or firmware that pretends to be something it isn't: a fake device, a tampered one sold as new, or a package or tool impersonating the real one. A counterfeit in our path can steal credentials or alter what we deploy.

The components we're responsible for:

- **Our own devices.** The Administrator's Mac and iPhone hold the phishing-resistant sign-in to Okta (Okta Verify FastPass), and through it, everything else.
- **Software we install or depend on:**
  - Go modules and Terraform providers;
  - the Python packages in our Lambda functions;
  - GitHub Actions;
  - the command-line tools we run (git, gh, terraform, the AWS CLI, Node and wrangler).

Not ours: the physical hardware of AWS, Okta, GitHub and Cloudflare. Each provider handles its own supply chain under its own authorization or security program.

## How counterfeits get in, and what we do about each

**Devices:**

- **Buy only from the manufacturer or its authorized resellers.** Apple directly, or a retailer Apple lists as authorized. Not marketplace third-party sellers, auctions, or "new" devices at prices that are too good.
- **Check on arrival:** sealed packaging, a serial number that matches the box, and the manufacturer's own coverage check (Apple: checkcoverage.apple.com).
- **Set up from a clean state:** reset or set up the device yourself, install updates from the manufacturer, then enrol it. Never enrol a device someone else set up.
- **Keep the receipt** and note the serial number in your records.

**Software:**

- **Get tools only from the official source:** the vendor's site, the official package manager, or the project's own GitHub releases. Not mirrors, forum links or emailed installers.
- **Verify what you install where the vendor provides a way:** a published checksum or signature, such as HashiCorp's signed release checksums for Terraform.
- **Dependencies stay pinned and checked in:** `go.sum`, Terraform's lock file, and `package-lock.json`. A changed checksum fails the build instead of silently installing something else.
- **GitHub Actions are pinned to a full commit SHA,** never a tag that can move. Our workflows already do this.
- **Watch for look-alike names** when adding a dependency (typosquatting). Check the publisher, the repository link and the download history before adding anything new. Every new dependency goes through a reviewed pull request.
- **Dependabot and Inspector alerts** are reviewed in the monthly vulnerability review (`vulnerability-review`).

## Warning signs

- A device or package that's cheaper than everywhere else, or "new" with broken or missing seals.
- A serial number that doesn't match, or that the manufacturer's check doesn't recognise.
- A software download whose checksum or signature doesn't match the vendor's.
- A dependency with a name one character off a well-known one, few downloads, or a recently changed owner.
- An unexpected prompt to install a "required update" from somewhere other than the vendor.

## If you suspect a counterfeit

1. **Stop using it.** Don't enrol the device, or don't run the software.
2. **Open an issue labelled `incident`** in this repository describing what you found. The incident response plan applies (`docs/policies/incident-response-pii.md`).
3. **Tell the seller and the manufacturer, or the vendor.**
4. **If it touched our sign-in or our build:** treat the credentials it could reach as exposed. Re-enrol authenticators, rotate tokens and keys, and check recent changes in the weekly audit log review.

## Record

In your yearly training issue, add: "Read the counterfeit components briefing (`docs/training/counterfeit-components.md`) on DATE."
