# AWS Deployment Notes

## Scanner Stack

- Stack name: `mc-compliance-aws-scanner`
- Region: `us-east-1`
- Lambda runtime: `python3.12`
- Lambda state: `Active`
- EventBridge rule state: `ENABLED`
- CloudWatch Logs group: `/aws/lambda/mc-compliance-aws-scanner-ComplianceScannerFunctio-vyAiRk7NFBTQ`

## EventBridge Pattern

The deployed rule listens for CloudTrail API events from:

- `s3.amazonaws.com`
- `ec2.amazonaws.com`

Tracked event names:

- `CreateBucket`
- `PutBucketAcl`
- `PutBucketPolicy`
- `PutPublicAccessBlock`
- `DeletePublicAccessBlock`
- `RunInstances`

## Notes

This document intentionally omits AWS account IDs and IAM role ARNs. Capture account-specific evidence in `evidence/` only after redaction.
