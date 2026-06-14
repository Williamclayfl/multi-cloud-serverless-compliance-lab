# GCP Deployment Notes

## Project Baseline

- Project ID: `mc-compliance-lab-wc-202606`
- Project number: `812437223722`
- Region: `us-east1`
- Billing: enabled
- Budget: `gcp-lab-monthly-budget`
- Budget amount: `25 USD` monthly
- Budget scope: project `812437223722`

## Budget Thresholds

- 50% current spend
- 80% current spend
- 100% current spend
- 50% forecasted spend

PowerShell needs quoted threshold flags when a rule includes both `percent` and `basis`:

```powershell
gcloud billing budgets create `
  --billing-account "<billing-account-id>" `
  --display-name "gcp-lab-monthly-budget" `
  --budget-amount 25USD `
  --calendar-period month `
  --filter-projects "projects/<project-id>" `
  "--threshold-rule=percent=0.50" `
  "--threshold-rule=percent=0.80" `
  "--threshold-rule=percent=1.00" `
  "--threshold-rule=percent=0.50,basis=forecasted-spend"
```

## Enabled APIs

- `run.googleapis.com`
- `eventarc.googleapis.com`
- `eventarcpublishing.googleapis.com`
- `pubsub.googleapis.com`
- `logging.googleapis.com`
- `cloudbuild.googleapis.com`
- `artifactregistry.googleapis.com`
- `storage.googleapis.com`
- `compute.googleapis.com`
- `cloudresourcemanager.googleapis.com`
- `iam.googleapis.com`

## Cloud Run Scanner

The GCP scanner uses Cloud Audit Logs routed through Eventarc to a private Cloud Run service.

Service:

- Cloud Run service: `gcp-compliance-scanner`
- Cloud Run URL: private service URL, redacted
- Latest validated revision: `gcp-compliance-scanner-00003-lbz`
- Runtime service account: `gcp-compliance-scanner`
- Eventarc trigger service account: `gcp-compliance-eventarc`
- Runtime source: `gcp-cloudrun-scanner/`
- Evidence log messages: `COMPLIANCE_SCAN`, `COMPLIANCE_VIOLATION`, `COMPLIANCE_SCAN_ERROR`

Detection rules:

- Public Cloud Storage bucket IAM grants to `allUsers` or `allAuthenticatedUsers`.
- Firewall rules open to the Internet for SSH or RDP.
- Compute Engine instances with external public IP addresses.
- Compute Engine instances missing required lab labels: `project`, `lab-resource`, `managed-by`.

Eventarc triggers:

- `storage.googleapis.com` / `storage.setIamPermissions`
- `compute.googleapis.com` / `v1.compute.firewalls.insert`
- `compute.googleapis.com` / `v1.compute.firewalls.patch`
- `compute.googleapis.com` / `v1.compute.firewalls.update`
- `compute.googleapis.com` / `v1.compute.instances.insert`

Validation:

- Unit tests: `5 passed`
- End-to-end Eventarc test: created a temporary firewall rule named `mc-compliance-open-ssh-test-2` that allowed TCP `22` from `0.0.0.0/0`.
- Cloud Logging evidence: revision `gcp-compliance-scanner-00003-lbz` wrote `COMPLIANCE_VIOLATION` with `resource_type=GCE_FIREWALL_RULE`, `resource_id=mc-compliance-open-ssh-test-2`, `severity=HIGH`, and `open_sensitive_ports=["22"]`.
- Cleanup: the temporary firewall rule was deleted after validation. The custom lab VPC `mc-compliance-lab-vpc` remains for future isolated tests.

Deploy:

```powershell
.\scripts\deploy-gcp-cloudrun-scanner.ps1 -ProjectId mc-compliance-lab-wc-202606 -Region us-east1
.\scripts\deploy-gcp-cloudrun-scanner.ps1 -ProjectId mc-compliance-lab-wc-202606 -Region us-east1 -Execute
```

Query evidence:

```powershell
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=gcp-compliance-scanner AND jsonPayload.message:(COMPLIANCE_SCAN OR COMPLIANCE_VIOLATION)" --project mc-compliance-lab-wc-202606 --limit 20 --format json
```

Generate repeatable firewall evidence:

```powershell
.\scripts\generate-gcp-chaos.ps1 -ProjectId mc-compliance-lab-wc-202606 -Region us-east1
.\scripts\generate-gcp-chaos.ps1 -ProjectId mc-compliance-lab-wc-202606 -Region us-east1 -Execute
```

The script creates a temporary firewall rule that allows TCP `22` from `0.0.0.0/0`, waits for the Cloud Run scanner to write a matching `COMPLIANCE_VIOLATION`, saves a redacted JSON sample to `evidence/gcp-cloudrun-firewall-violation-sample.json`, and deletes the temporary rule in a cleanup block.

Generate repeatable public bucket IAM evidence:

```powershell
.\scripts\generate-gcp-storage-chaos.ps1 -ProjectId mc-compliance-lab-wc-202606 -Location us-east1
.\scripts\generate-gcp-storage-chaos.ps1 -ProjectId mc-compliance-lab-wc-202606 -Location us-east1 -Execute
```

The script creates a temporary empty bucket, grants `allUsers` the `roles/storage.objectViewer` role, waits for the Cloud Run scanner to write a matching `COMPLIANCE_VIOLATION`, saves a redacted JSON sample to `evidence/gcp-cloudrun-storage-iam-violation-sample.json`, removes the public IAM binding, and deletes the temporary bucket.

This document intentionally omits personal account details. Keep raw provider exports under `evidence/raw/` until redacted.
