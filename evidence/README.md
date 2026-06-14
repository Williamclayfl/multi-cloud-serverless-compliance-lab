# Evidence Index

This folder contains redacted evidence for the Multi-Cloud Serverless Compliance Lab. Keep raw screenshots, CSV exports, and provider-console downloads under `evidence/raw/` until they are redacted.

## Committed Evidence

| File | Provider | Proves | Redaction Notes |
| --- | --- | --- | --- |
| `azure-policy-enforced-sample.csv` | Azure | PowerShell Azure Function remediated Internet-open NSG rules and wrote `POLICY ENFORCED` traces | Review before sharing for subscription IDs, public IPs, and personal identifiers |
| `gcp-cloudrun-firewall-violation-sample.json` | GCP | Cloud Run scanner detected a Compute firewall rule allowing SSH from `0.0.0.0/0` | Project ID is redacted |
| `gcp-cloudrun-storage-iam-violation-sample.json` | GCP | Cloud Run scanner detected a Cloud Storage bucket IAM grant to `allUsers` | Project ID is redacted |

## Evidence To Capture Before Portfolio Submission

Capture screenshots or exports showing:

- GitHub repository front page with the updated README and validated controls table.
- AWS CloudFormation stack `mc-compliance-aws-scanner` in `CREATE_COMPLETE`.
- AWS Lambda function state `Active`.
- AWS EventBridge rule state `ENABLED`.
- AWS CloudWatch Logs entry showing S3 `COMPLIANCE_VIOLATION`.
- AWS CloudTrail `RunInstances` event showing `Client.Blocked` for the provider/account-verification constraint.
- GCP Cloud Run service `gcp-compliance-scanner`.
- GCP Eventarc triggers for Storage IAM, Compute firewall, and Compute instance events.
- GCP Cloud Logging entries for `GCE_FIREWALL_RULE` and `GCS_BUCKET` `COMPLIANCE_VIOLATION`.
- GCP budget `gcp-lab-monthly-budget`.
- GCP VPC `mc-compliance-lab-vpc`.
- Azure Function App for NSG remediation.
- Azure Application Insights traces showing `POLICY ENFORCED`.
- Azure budget guardrail.

## Screenshot Redaction Checklist

Before committing or sharing screenshots, redact:

- AWS account IDs, IAM role ARNs, access key IDs, and source IP addresses.
- GCP project numbers, billing account IDs, service account emails, and public IP addresses.
- Azure subscription IDs, tenant IDs, resource IDs, function keys, and public IP addresses.
- Personal email addresses and browser profile identifiers.

## Evidence Commands

AWS CloudWatch evidence:

```powershell
aws logs filter-log-events `
  --log-group-name /aws/lambda/mc-compliance-aws-scanner-ComplianceScannerFunctio-vyAiRk7NFBTQ `
  --filter-pattern COMPLIANCE_VIOLATION `
  --limit 10 `
  --region us-east-1 `
  --profile codex-admin `
  --output json
```

GCP Cloud Logging evidence:

```powershell
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=gcp-compliance-scanner AND jsonPayload.message=COMPLIANCE_VIOLATION" --project mc-compliance-lab-wc-202606 --limit 20 --format json
```

Azure Application Insights evidence depends on the deployed workspace/app names. Export only redacted trace rows that show `POLICY ENFORCED`.
