param(
    [string]$ProjectId = $env:GCP_PROJECT_ID,
    [string]$BillingAccountId = $env:GCP_BILLING_ACCOUNT_ID,
    [string]$BudgetName = 'gcp-lab-monthly-budget',
    [int]$Amount = 25
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectId)) {
    throw 'ProjectId is required. Pass -ProjectId or set GCP_PROJECT_ID.'
}

if ([string]::IsNullOrWhiteSpace($BillingAccountId)) {
    throw 'BillingAccountId is required. Pass -BillingAccountId or set GCP_BILLING_ACCOUNT_ID.'
}

$gcloud = Get-Command gcloud -ErrorAction SilentlyContinue
if (-not $gcloud) {
    $defaultPath = Join-Path $env:LOCALAPPDATA 'Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'
    if (Test-Path -LiteralPath $defaultPath) {
        $gcloudPath = $defaultPath
    }
    else {
        throw 'Google Cloud CLI was not found. Install Google Cloud SDK and reopen PowerShell.'
    }
}
else {
    $gcloudPath = $gcloud.Source
}

Write-Host "Linking project $ProjectId to billing account $BillingAccountId"
& $gcloudPath billing projects link $ProjectId --billing-account $BillingAccountId

Write-Host 'Enabling Billing Budgets API'
& $gcloudPath services enable billingbudgets.googleapis.com --project $ProjectId

Write-Host "Creating budget $BudgetName"
& $gcloudPath billing budgets create `
    --billing-account $BillingAccountId `
    --display-name $BudgetName `
    --budget-amount "$Amount`USD" `
    --calendar-period month `
    --filter-projects "projects/$ProjectId" `
    '--threshold-rule=percent=0.50' `
    '--threshold-rule=percent=0.80' `
    '--threshold-rule=percent=1.00' `
    '--threshold-rule=percent=0.50,basis=forecasted-spend'

Write-Host 'Budget setup complete.'
