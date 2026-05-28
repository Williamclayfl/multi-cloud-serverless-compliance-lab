# Security Notes

## Credential Handling

- Do not commit `.env`, `local.settings.json`, AWS credentials, Azure publish profiles, private keys, or function keys.
- Use GitHub MFA and browser-based authentication for VS Code or GitHub CLI.
- Use AWS IAM Identity Center/SSO instead of long-lived IAM user keys.
- Use Azure managed identity for the Function App instead of storing service principal secrets.

## Lab Exposure

This project intentionally creates insecure states for detection and remediation practice. Keep those states constrained:

- Empty S3 buckets only.
- No real customer, employer, school, or personal data.
- Dedicated AWS lab account or dedicated region.
- Dedicated Azure lab resource group.
- Short-lived public S3 ACL or NSG exposure windows.
- Cleanup script or manual teardown immediately after evidence collection.

## Evidence Redaction

Before committing evidence, redact:

- AWS account IDs and ARNs if they identify the account.
- Azure subscription and tenant IDs.
- Public IP addresses that belong to you or your workplace.
- Emails, usernames, function keys, SAS tokens, and URLs with secrets.
