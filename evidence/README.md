# Evidence Index

This folder contains redacted evidence for the Multi-Cloud Serverless Compliance Lab. Keep raw provider-console downloads and unredacted exports out of Git.

## Committed Evidence

| File | Provider | Proves | Redaction Notes |
| --- | --- | --- | --- |
| `azure-policy-enforced-sample.csv` | Azure | PowerShell Azure Function remediated Internet-open NSG rules and wrote `POLICY ENFORCED` traces | Redacted sample export |
| `gcp-cloudrun-firewall-violation-sample.json` | GCP | Cloud Run scanner detected a Compute firewall rule allowing SSH from `0.0.0.0/0` | Project ID is redacted |
| `gcp-cloudrun-storage-iam-violation-sample.json` | GCP | Cloud Run scanner detected a Cloud Storage bucket IAM grant to `allUsers` | Project ID is redacted |

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
