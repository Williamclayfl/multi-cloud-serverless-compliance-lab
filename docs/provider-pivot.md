# Provider Constraint And Pivot

## Summary

This lab began with AWS as the primary detection path, then pivoted to GCP for the remaining storage, network, and compute-style evidence after an AWS account-verification block prevented real EC2 launches.

The pivot was an intentional engineering decision: preserve the working AWS scanner evidence, avoid waiting indefinitely on a provider-side account issue, and complete the multi-cloud compliance story with equivalent event-driven controls on GCP.

## AWS Status

The AWS implementation is still valid project evidence:

- CloudFormation stack `mc-compliance-aws-scanner` deployed successfully.
- Lambda scanner is active.
- EventBridge rule is enabled and targets the Lambda scanner.
- CloudTrail trail `mc-compliance-lab-trail` is logging management events.
- CloudWatch Logs contain `COMPLIANCE_SCAN` and `COMPLIANCE_VIOLATION` entries.
- S3 public bucket policy detection was validated on May 29, 2026.

The unresolved AWS gap is EC2 launch capability:

- EC2 `RunInstances` dry-run checks showed that the request path and permissions were viable.
- Real EC2 `RunInstances` attempts failed with `Client.Blocked`.
- CloudTrail recorded the latest known real launch failure on June 3, 2026.
- The failure message pointed to AWS account verification, not to this project's scanner code or IAM policy.

## Decision

Instead of removing AWS or repeatedly rebuilding the same account path, the project keeps AWS as a partially validated provider and uses the blocked EC2 launch as documented operational risk.

The project then pivots to GCP to complete comparable evidence:

- Cloud Audit Logs provide the event stream.
- Eventarc routes audit events to a private Cloud Run service.
- Cloud Run performs compliance checks and writes structured evidence to Cloud Logging.
- Guarded scripts generate repeatable, short-lived violations and clean up immediately.

## GCP Evidence Added

The GCP path validates two real controls without relying on billable VM launches:

- Firewall rule detection: temporary SSH exposure from `0.0.0.0/0` produces a high-severity `GCE_FIREWALL_RULE` finding.
- Storage IAM detection: temporary `allUsers` bucket IAM access produces a high-severity `GCS_BUCKET` finding.

Evidence files:

- `evidence/gcp-cloudrun-firewall-violation-sample.json`
- `evidence/gcp-cloudrun-storage-iam-violation-sample.json`

Guarded scripts:

- `scripts/generate-gcp-chaos.ps1`
- `scripts/generate-gcp-storage-chaos.ps1`

## Portfolio Framing

This is the intended portfolio takeaway:

> Built an event-driven multi-cloud compliance lab across AWS, GCP, and Azure. When AWS EC2 launches were blocked by account verification, preserved validated AWS S3 evidence and pivoted to GCP Cloud Run/Eventarc to complete repeatable network and storage compliance evidence.

The pivot demonstrates practical cloud engineering judgment: verify what works, isolate provider/account constraints, keep evidence redacted, and move to a viable architecture that satisfies the same compliance goals.
