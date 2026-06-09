param(
    [string]$ProjectId = $env:GCP_PROJECT_ID,
    [string]$Location = $(if ($env:GCP_REGION) { $env:GCP_REGION } else { 'us-east1' }),
    [string]$ServiceName = 'gcp-compliance-scanner',
    [string]$BucketName = '',
    [string]$PublicMember = 'allUsers',
    [string]$PublicRole = 'roles/storage.objectViewer',
    [int]$WaitSeconds = 240,
    [int]$PollSeconds = 10,
    [string]$EvidencePath = 'evidence/gcp-cloudrun-storage-iam-violation-sample.json',
    [switch]$KeepBucket,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ([string]::IsNullOrWhiteSpace($ProjectId)) {
    throw 'ProjectId is required. Pass -ProjectId or set GCP_PROJECT_ID.'
}

if ($WaitSeconds -lt 30) {
    throw 'WaitSeconds must be at least 30 so Eventarc has time to deliver the audit event.'
}

if ($PollSeconds -lt 5) {
    throw 'PollSeconds must be at least 5 to avoid noisy Cloud Logging polling.'
}

if ([string]::IsNullOrWhiteSpace($BucketName)) {
    $randomSuffix = '{0:d6}' -f (Get-Random -Minimum 0 -Maximum 999999)
    $BucketName = "mc-compliance-public-iam-$(Get-Date -Format 'yyyyMMddHHmmss')-$randomSuffix"
}

if ($BucketName -cnotmatch '^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$') {
    throw "BucketName must be a valid Cloud Storage bucket name: $BucketName"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([System.IO.Path]::IsPathRooted($EvidencePath)) {
    $resolvedEvidencePath = $EvidencePath
}
else {
    $resolvedEvidencePath = Join-Path $repoRoot $EvidencePath
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

Write-Host 'GCP public bucket IAM evidence generation plan'
Write-Host "Project:              $ProjectId"
Write-Host "Cloud Run service:    $ServiceName"
Write-Host "Bucket location:      $Location"
Write-Host "Temporary bucket:     gs://$BucketName"
Write-Host "Temporary grant:      $PublicMember -> $PublicRole"
Write-Host "Evidence path:        $resolvedEvidencePath"
Write-Host "Wait window:          $WaitSeconds seconds"
Write-Host "Mode:                 $(if ($Execute) { 'Execute' } else { 'Dry run' })"

if (-not $Execute) {
    Write-Host ''
    Write-Host 'Dry run only. Re-run with -Execute to create the temporary bucket, add public IAM, wait for evidence, and clean up.'
    return
}

function Invoke-Gcloud {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & $gcloudPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gcloud command failed: gcloud $($Arguments -join ' ')"
    }
}

function Invoke-GcloudCapture {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $output = & $gcloudPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gcloud command failed: gcloud $($Arguments -join ' ')`n$output"
    }
    return ($output | Out-String).Trim()
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

function Invoke-GcloudCleanup {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $gcloudPath @Arguments
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Cleanup command failed: gcloud $($Arguments -join ' ')"
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-FirstLogEntry {
    param([string]$Filter)

    $json = Invoke-GcloudCapture logging read $Filter --project $ProjectId --limit 1 --format json
    if ([string]::IsNullOrWhiteSpace($json) -or $json.Trim() -eq '[]') {
        return $null
    }

    $entries = @($json | ConvertFrom-Json)
    if ($entries.Count -eq 0) {
        return $null
    }

    return $entries[0]
}

function Save-RedactedEvidence {
    param([object]$LogEntry)

    $directory = Split-Path -Parent $resolvedEvidencePath
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $payload = $LogEntry.jsonPayload
    $resourceLabels = $LogEntry.resource.labels
    $evidence = [ordered]@{
        generated_at_utc = [DateTime]::UtcNow.ToString('o')
        source = 'gcloud logging read'
        project_id = 'redacted'
        event_timestamp = $LogEntry.timestamp
        cloud_run_service = $resourceLabels.service_name
        cloud_run_revision = $resourceLabels.revision_name
        message = $payload.message
        severity = $payload.severity
        resource_type = $payload.resource_type
        resource_id = $payload.resource_id
        event_name = $payload.event_name
        public_bindings = @($payload.public_bindings)
        recommendation = $payload.recommendation
    }

    $evidence | ConvertTo-Json -Depth 8 | Set-Content -Path $resolvedEvidencePath -Encoding UTF8
}

$createdBucket = $false
$addedPublicBinding = $false

try {
    Invoke-Gcloud config set project $ProjectId | Out-Null

    $latestRevision = Invoke-GcloudOptionalValue run services describe $ServiceName --region $Location --project $ProjectId --format 'value(status.latestReadyRevisionName)'
    if (-not $latestRevision) {
        throw "Cloud Run service was not found: $ServiceName in $Location"
    }
    Write-Host "Scanner revision:     $latestRevision"

    $existingBucket = Invoke-GcloudOptionalValue storage buckets describe "gs://$BucketName" --project $ProjectId --format 'value(name)'
    if ($existingBucket) {
        throw "Bucket already exists and will not be modified: gs://$BucketName"
    }

    Write-Host "Creating temporary empty bucket: gs://$BucketName"
    Invoke-Gcloud storage buckets create "gs://$BucketName" `
        --project $ProjectId `
        --location $Location `
        --uniform-bucket-level-access `
        --no-public-access-prevention `
        --default-storage-class STANDARD `
        --quiet
    $createdBucket = $true

    Write-Host "Adding temporary public IAM binding: $PublicMember -> $PublicRole"
    Invoke-Gcloud storage buckets add-iam-policy-binding "gs://$BucketName" `
        --project $ProjectId `
        --member $PublicMember `
        --role $PublicRole `
        --quiet
    $addedPublicBinding = $true

    $filter = "resource.type=cloud_run_revision AND resource.labels.service_name=$ServiceName AND jsonPayload.message=COMPLIANCE_VIOLATION AND jsonPayload.resource_type=GCS_BUCKET AND jsonPayload.resource_id=$BucketName"
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $logEntry = $null

    Write-Host "Waiting for COMPLIANCE_VIOLATION evidence in Cloud Logging..."
    while ((Get-Date) -lt $deadline) {
        $logEntry = Get-FirstLogEntry -Filter $filter
        if ($logEntry) {
            break
        }

        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $logEntry) {
        throw "Timed out after $WaitSeconds seconds waiting for Cloud Logging evidence for gs://$BucketName."
    }

    Save-RedactedEvidence -LogEntry $logEntry
    Write-Host "Evidence written: $resolvedEvidencePath"
    Write-Host "Violation: $($logEntry.jsonPayload.severity) $($logEntry.jsonPayload.resource_type) $($logEntry.jsonPayload.resource_id)"
}
finally {
    if ($addedPublicBinding -and -not $KeepBucket) {
        Write-Host "Removing temporary public IAM binding from gs://$BucketName"
        Invoke-GcloudCleanup storage buckets remove-iam-policy-binding "gs://$BucketName" `
            --project $ProjectId `
            --member $PublicMember `
            --role $PublicRole `
            --quiet
    }
    elseif ($addedPublicBinding) {
        Write-Warning "Temporary public IAM binding kept because -KeepBucket was set: gs://$BucketName"
    }

    if ($createdBucket -and -not $KeepBucket) {
        Write-Host "Deleting temporary bucket: gs://$BucketName"
        Invoke-GcloudCleanup storage buckets delete "gs://$BucketName" --project $ProjectId --quiet
    }
    elseif ($createdBucket) {
        Write-Warning "Temporary bucket kept by request: gs://$BucketName"
    }
}
