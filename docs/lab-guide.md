# Multi-Cloud Serverless Compliance Lab Guide

## Prerequisites

- VS Code with the recommended extensions from `.vscode/extensions.json`.
- Git authenticated to GitHub.
- AWS CLI authenticated with the `codex-admin` SSO profile.
- AWS SAM CLI for Lambda deployment.
- Azure CLI and Azure Functions Core Tools.
- Google Cloud CLI.
- A dedicated AWS lab account, GCP project, and Azure lab resource group.

Run:

```powershell
.\scripts\check-prereqs.ps1
```

## Phase 1: Boundaries And Baseline

1. Create AWS, GCP, and Azure budgets with alert notifications.
2. Confirm the lab is isolated from production data.
3. Enable AWS CloudTrail management events.
4. Create or confirm the Azure resource group that will hold lab VNets and NSGs.
5. Document the corporate-approved test source prefix in `SANCTIONED_SOURCE_PREFIX`.

Current Azure lab defaults:

```powershell
$env:AZURE_TENANT_ID = "<your-tenant-id>"
$env:AZURE_SUBSCRIPTION_ID = "<your-subscription-id>"
az login --tenant $env:AZURE_TENANT_ID --use-device-code --subscription $env:AZURE_SUBSCRIPTION_ID
az account set --subscription $env:AZURE_SUBSCRIPTION_ID
az group create --name rg-mc-compliance-lab-eastus --location eastus
```

Use `.env.example` as the local reference for non-secret lab names and regions.

Create or update the subscription-scoped Azure budget:

```powershell
.\scripts\create-azure-subscription-budget.ps1 -ContactEmails "you@example.com" -Amount 25
```

The default budget name is `lab-subscription-monthly-budget`. If a budget already exists with a different time grain, Azure requires a new budget name or delete/recreate of the old budget.

Current GCP lab defaults:

```powershell
$env:GCP_PROJECT_ID = "mc-compliance-lab-wc-202606"
$env:GCP_PROJECT_NUMBER = "812437223722"
$env:GCP_REGION = "us-east1"
$env:GCP_BILLING_ACCOUNT_ID = "<your-billing-account-id>"
gcloud config set project $env:GCP_PROJECT_ID
```

The GCP project has billing attached and a project-scoped monthly budget named `gcp-lab-monthly-budget` for 25 USD. It alerts at 50%, 80%, and 100% current spend, plus 50% forecasted spend.

## Phase 2: AWS Scanner

1. Sign in:

```powershell
aws sso login --profile codex-admin
```

2. Deploy from VS Code using the task `AWS: SAM guided deploy`, or run:

```powershell
sam build --template-file aws-lambda-scanner/template.yaml
sam deploy --template-file .aws-sam/build/template.yaml --stack-name mc-compliance-aws-scanner --region us-east-1 --profile codex-admin --capabilities CAPABILITY_IAM --resolve-s3 --no-confirm-changeset --no-fail-on-empty-changeset
```

3. Create lab-only S3 buckets and EC2 test instances.
4. Trigger changes such as `PutBucketAcl` and `RunInstances`.
5. Verify CloudWatch logs contain `COMPLIANCE_SCAN` and `COMPLIANCE_VIOLATION`.

## Phase 3: Azure Enforcer

1. Sign in:

```powershell
$env:AZURE_TENANT_ID = "<your-tenant-id>"
$env:AZURE_SUBSCRIPTION_ID = "<your-subscription-id>"
az login --tenant $env:AZURE_TENANT_ID --use-device-code --subscription $env:AZURE_SUBSCRIPTION_ID
az account set --subscription $env:AZURE_SUBSCRIPTION_ID
```

2. Review the deployment plan:

```powershell
.\scripts\deploy-azure-function-enforcer.ps1
```

3. Deploy the Function App, managed identity, resource-group-scoped `Network Contributor` assignment, Action Group webhook, and Activity Log alerts:

```powershell
.\scripts\deploy-azure-function-enforcer.ps1 -Execute
```

The script creates the Function App on the Windows Consumption plan so PowerShell managed dependencies can install `Az.Accounts` and `Az.Network` from `requirements.psd1`. The webhook uses the common alert schema and the function key is never written to source files.

4. Create the isolated lab VNets and intentionally open NSG rules:

```powershell
.\scripts\create-azure-dummy-nsgs.ps1
.\scripts\create-azure-dummy-nsgs.ps1 -Execute
```

5. Verify Application Insights traces contain `POLICY ENFORCED`.

The Azure implementation follows the Microsoft Learn guidance that PowerShell Functions use `function.json` bindings, `Push-OutputBinding` for HTTP responses, managed dependencies via `requirements.psd1`, `Set-AzNetworkSecurityRuleConfig` or equivalent NSG object updates for custom security rules, and Activity Log alerts routed through Action Groups with the common alert schema.

## Phase 3b: GCP Scanner

The GCP implementation is the contingency path for completing the multi-cloud lab while AWS EC2 creation remains blocked at the account-verification layer.

Event flow:

```text
Cloud Audit Logs -> Eventarc -> Cloud Run service -> Cloud Logging evidence
```

Initial checks:

- Cloud Storage buckets with public IAM grants.
- Firewall rules open to `0.0.0.0/0` for SSH or RDP.
- Compute Engine VMs with external public IPs.
- Required lab labels on Compute Engine instances.

Enabled APIs:

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

Deploy the scanner:

```powershell
.\scripts\deploy-gcp-cloudrun-scanner.ps1 -ProjectId mc-compliance-lab-wc-202606 -Region us-east1
.\scripts\deploy-gcp-cloudrun-scanner.ps1 -ProjectId mc-compliance-lab-wc-202606 -Region us-east1 -Execute
```

The script creates two user-managed service accounts, a project custom role for read-only scanner permissions, the private Cloud Run service, and Eventarc triggers for Storage IAM changes, Compute firewall rule writes, and Compute instance creates.

Verify Cloud Logging evidence:

```powershell
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=gcp-compliance-scanner AND jsonPayload.message:(COMPLIANCE_SCAN OR COMPLIANCE_VIOLATION)" --project mc-compliance-lab-wc-202606 --limit 20 --format json
```

Generate a repeatable redacted firewall evidence sample:

```powershell
.\scripts\generate-gcp-chaos.ps1 -ProjectId mc-compliance-lab-wc-202606 -Region us-east1
.\scripts\generate-gcp-chaos.ps1 -ProjectId mc-compliance-lab-wc-202606 -Region us-east1 -Execute
```

## Phase 4: Metrics

AWS:

```powershell
.\scripts\generate-aws-chaos.ps1 -BucketNames lab-bucket-1,lab-bucket-2 -Iterations 25
```

Add `-Execute` only after confirming the buckets are empty lab resources and public ACL testing is intentionally allowed.

Azure:

```powershell
.\scripts\generate-azure-chaos.ps1 -ResourceGroupName rg-mc-compliance-lab-eastus -NetworkSecurityGroupName nsg-mc-compliance-lab-01 -Iterations 25
```

Add `-Execute` only after confirming this NSG is isolated to the lab.

## Phase 5: Evidence

Export redacted evidence only:

- CloudWatch Logs query results showing `COMPLIANCE_SCAN` and `COMPLIANCE_VIOLATION`.
- Cloud Logging query results showing GCP compliance scans and violations.
- Application Insights traces showing `POLICY ENFORCED`.
- Screenshots of budget alerts, IAM/RBAC scoping, and serverless deployment resources.

Never commit raw account IDs, subscription IDs, access keys, function keys, IP allowlists, or personal email addresses.
