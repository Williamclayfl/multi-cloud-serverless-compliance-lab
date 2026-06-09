param(
    [string]$ProjectId = $env:GCP_PROJECT_ID,
    [string]$Region = $(if ($env:GCP_REGION) { $env:GCP_REGION } else { 'us-east1' }),
    [string]$ServiceName = 'gcp-compliance-scanner',
    [string]$NetworkName = 'mc-compliance-lab-vpc',
    [string]$RuleName = '',
    [string]$SourceRange = '0.0.0.0/0',
    [int]$WaitSeconds = 240,
    [int]$PollSeconds = 10,
    [string]$EvidencePath = 'evidence/gcp-cloudrun-firewall-violation-sample.json',
    [switch]$CreateNetworkIfMissing,
    [switch]$KeepFirewallRule,
    [switch]$KeepNetwork,
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

if ([string]::IsNullOrWhiteSpace($RuleName)) {
    $RuleName = "mc-compliance-open-ssh-$(Get-Date -Format 'yyyyMMddHHmmss')"
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

Write-Host 'GCP firewall evidence generation plan'
Write-Host "Project:              $ProjectId"
Write-Host "Cloud Run service:    $ServiceName"
Write-Host "Cloud Run region:     $Region"
Write-Host "Network:              $NetworkName"
Write-Host "Temporary rule:       $RuleName"
Write-Host "Temporary exposure:   tcp:22 from $SourceRange"
Write-Host "Evidence path:        $resolvedEvidencePath"
Write-Host "Wait window:          $WaitSeconds seconds"
Write-Host "Mode:                 $(if ($Execute) { 'Execute' } else { 'Dry run' })"

if (-not $Execute) {
    Write-Host ''
    Write-Host 'Dry run only. Re-run with -Execute to create the temporary firewall rule, wait for Cloud Logging evidence, and clean up.'
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
        open_sensitive_ports = @($payload.open_sensitive_ports)
        source_ranges = @($payload.source_ranges)
        recommendation = $payload.recommendation
    }

    $evidence | ConvertTo-Json -Depth 8 | Set-Content -Path $resolvedEvidencePath -Encoding UTF8
}

$createdRule = $false
$createdNetwork = $false

try {
    Invoke-Gcloud config set project $ProjectId | Out-Null

    $latestRevision = Invoke-GcloudOptionalValue run services describe $ServiceName --region $Region --project $ProjectId --format 'value(status.latestReadyRevisionName)'
    if (-not $latestRevision) {
        throw "Cloud Run service was not found: $ServiceName in $Region"
    }
    Write-Host "Scanner revision:     $latestRevision"

    $existingNetwork = Invoke-GcloudOptionalValue compute networks describe $NetworkName --project $ProjectId --format 'value(name)'
    if (-not $existingNetwork) {
        if (-not $CreateNetworkIfMissing) {
            throw "Network was not found: $NetworkName. Create it first or re-run with -CreateNetworkIfMissing."
        }

        Write-Host "Creating temporary custom VPC: $NetworkName"
        Invoke-Gcloud compute networks create $NetworkName --subnet-mode custom --project $ProjectId --quiet
        $createdNetwork = $true
    }

    $existingRule = Invoke-GcloudOptionalValue compute firewall-rules describe $RuleName --project $ProjectId --format 'value(name)'
    if ($existingRule) {
        throw "Firewall rule already exists and will not be modified: $RuleName"
    }

    Write-Host "Creating temporary firewall rule: $RuleName"
    Invoke-Gcloud compute firewall-rules create $RuleName `
        --project $ProjectId `
        --network $NetworkName `
        --direction INGRESS `
        --priority 1000 `
        --allow tcp:22 `
        --source-ranges $SourceRange `
        --description 'Temporary lab-only rule for Cloud Run compliance scanner evidence.' `
        --quiet
    $createdRule = $true

    $filter = "resource.type=cloud_run_revision AND resource.labels.service_name=$ServiceName AND jsonPayload.message=COMPLIANCE_VIOLATION AND jsonPayload.resource_type=GCE_FIREWALL_RULE AND jsonPayload.resource_id=$RuleName"
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
        throw "Timed out after $WaitSeconds seconds waiting for Cloud Logging evidence for $RuleName."
    }

    Save-RedactedEvidence -LogEntry $logEntry
    Write-Host "Evidence written: $resolvedEvidencePath"
    Write-Host "Violation: $($logEntry.jsonPayload.severity) $($logEntry.jsonPayload.resource_type) $($logEntry.jsonPayload.resource_id)"
}
finally {
    if ($createdRule -and -not $KeepFirewallRule) {
        Write-Host "Deleting temporary firewall rule: $RuleName"
        Invoke-Gcloud compute firewall-rules delete $RuleName --project $ProjectId --quiet
    }
    elseif ($createdRule) {
        Write-Warning "Temporary firewall rule kept by request: $RuleName"
    }

    if ($createdNetwork -and -not $KeepNetwork) {
        Write-Host "Deleting temporary VPC: $NetworkName"
        Invoke-Gcloud compute networks delete $NetworkName --project $ProjectId --quiet
    }
    elseif ($createdNetwork) {
        Write-Warning "Temporary VPC kept by request: $NetworkName"
    }
}
