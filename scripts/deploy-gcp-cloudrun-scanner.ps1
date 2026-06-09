param(
    [string]$ProjectId = $env:GCP_PROJECT_ID,
    [string]$Region = $(if ($env:GCP_REGION) { $env:GCP_REGION } else { 'us-east1' }),
    [string]$ServiceName = 'gcp-compliance-scanner',
    [string]$RuntimeServiceAccountName = 'gcp-compliance-scanner',
    [string]$TriggerServiceAccountName = 'gcp-compliance-eventarc',
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ([string]::IsNullOrWhiteSpace($ProjectId)) {
    throw 'ProjectId is required. Pass -ProjectId or set GCP_PROJECT_ID.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$servicePath = Join-Path $repoRoot 'gcp-cloudrun-scanner'
$roleId = 'gcpComplianceScannerReader'
$runtimeServiceAccount = "$RuntimeServiceAccountName@$ProjectId.iam.gserviceaccount.com"
$triggerServiceAccount = "$TriggerServiceAccountName@$ProjectId.iam.gserviceaccount.com"

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

Write-Host 'GCP Cloud Run scanner deployment plan'
Write-Host "Project:                 $ProjectId"
Write-Host "Region:                  $Region"
Write-Host "Service:                 $ServiceName"
Write-Host "Runtime service account: $runtimeServiceAccount"
Write-Host "Trigger service account: $triggerServiceAccount"
Write-Host "Source folder:           $servicePath"
Write-Host "Mode:                    $(if ($Execute) { 'Execute' } else { 'Dry run' })"

if (-not $Execute) {
    Write-Host ''
    Write-Host 'Dry run only. Re-run with -Execute to create IAM, deploy Cloud Run, and create Eventarc triggers.'
    return
}

function Invoke-Gcloud {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & $gcloudPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gcloud command failed: gcloud $($Arguments -join ' ')"
    }
}

function Invoke-GcloudOptionalValue {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $gcloudPath @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) {
            return ''
        }
        return ($output | Out-String).Trim()
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

Invoke-Gcloud config set project $ProjectId

Invoke-Gcloud services enable `
    run.googleapis.com `
    eventarc.googleapis.com `
    eventarcpublishing.googleapis.com `
    pubsub.googleapis.com `
    logging.googleapis.com `
    cloudbuild.googleapis.com `
    artifactregistry.googleapis.com `
    storage.googleapis.com `
    compute.googleapis.com `
    cloudresourcemanager.googleapis.com `
    iam.googleapis.com `
    --project $ProjectId

$existingRuntimeSa = Invoke-GcloudOptionalValue iam service-accounts describe $runtimeServiceAccount --project $ProjectId --format='value(email)'
if (-not $existingRuntimeSa) {
    Invoke-Gcloud iam service-accounts create $RuntimeServiceAccountName `
        --display-name 'GCP compliance scanner runtime' `
        --description 'Reads selected lab resource state for compliance evidence.' `
        --project $ProjectId
}

$existingTriggerSa = Invoke-GcloudOptionalValue iam service-accounts describe $triggerServiceAccount --project $ProjectId --format='value(email)'
if (-not $existingTriggerSa) {
    Invoke-Gcloud iam service-accounts create $TriggerServiceAccountName `
        --display-name 'GCP compliance scanner Eventarc trigger' `
        --description 'Invokes the Cloud Run scanner from Eventarc.' `
        --project $ProjectId
}

$roleExists = Invoke-GcloudOptionalValue iam roles describe $roleId --project $ProjectId --format='value(name)'
if (-not $roleExists) {
    Invoke-Gcloud iam roles create $roleId `
        --project $ProjectId `
        --title 'GCP Compliance Scanner Reader' `
        --description 'Read-only permissions needed by the lab compliance scanner.' `
        --permissions 'storage.buckets.get,storage.buckets.getIamPolicy,compute.firewalls.get,compute.instances.get' `
        --stage GA
}

Invoke-Gcloud projects add-iam-policy-binding $ProjectId `
    --member "serviceAccount:$runtimeServiceAccount" `
    --role "projects/$ProjectId/roles/$roleId" `
    --condition=None

Invoke-Gcloud projects add-iam-policy-binding $ProjectId `
    --member "serviceAccount:$triggerServiceAccount" `
    --role roles/eventarc.eventReceiver `
    --condition=None

Invoke-Gcloud run deploy $ServiceName `
    --source $servicePath `
    --region $Region `
    --service-account $runtimeServiceAccount `
    --no-allow-unauthenticated `
    --set-env-vars "GCP_PROJECT_ID=$ProjectId,REQUIRED_LABELS=project;lab-resource;managed-by" `
    --labels "project=multi-cloud-compliance-lab,managed-by=codex,lab-resource=true" `
    --project $ProjectId `
    --quiet

Invoke-Gcloud run services add-iam-policy-binding $ServiceName `
    --region $Region `
    --member "serviceAccount:$triggerServiceAccount" `
    --role roles/run.invoker `
    --project $ProjectId

$triggers = @(
    @{ Name = 'gcp-scanner-storage-iam'; Location = $Region; Service = 'storage.googleapis.com'; Method = 'storage.setIamPermissions' },
    @{ Name = 'gcp-scanner-firewall-insert'; Location = 'global'; Service = 'compute.googleapis.com'; Method = 'v1.compute.firewalls.insert' },
    @{ Name = 'gcp-scanner-firewall-patch'; Location = 'global'; Service = 'compute.googleapis.com'; Method = 'v1.compute.firewalls.patch' },
    @{ Name = 'gcp-scanner-firewall-update'; Location = 'global'; Service = 'compute.googleapis.com'; Method = 'v1.compute.firewalls.update' },
    @{ Name = 'gcp-scanner-instance-insert'; Location = 'us-central1'; Service = 'compute.googleapis.com'; Method = 'v1.compute.instances.insert' }
)

foreach ($trigger in $triggers) {
    $existingTrigger = Invoke-GcloudOptionalValue eventarc triggers describe $trigger.Name --location $trigger.Location --project $ProjectId --format='value(name)'
    if ($existingTrigger) {
        Write-Host "Eventarc trigger already exists: $($trigger.Name)"
        continue
    }

    Invoke-Gcloud eventarc triggers create $trigger.Name `
        --location $trigger.Location `
        --destination-run-service $ServiceName `
        --destination-run-region $Region `
        --event-filters 'type=google.cloud.audit.log.v1.written' `
        --event-filters "serviceName=$($trigger.Service)" `
        --event-filters "methodName=$($trigger.Method)" `
        --event-data-content-type 'application/json' `
        --service-account $triggerServiceAccount `
        --labels "project=multi-cloud-compliance-lab,managed-by=codex,lab-resource=true" `
        --project $ProjectId `
        --quiet
}

Write-Host 'GCP Cloud Run scanner deployment complete.'
