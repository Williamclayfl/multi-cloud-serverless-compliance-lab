param(
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$TenantId = $env:AZURE_TENANT_ID,
    [string]$ResourceGroupName = 'rg-mc-compliance-lab-eastus',
    [string]$Location = 'eastus',
    [string]$FunctionAppName,
    [string]$StorageAccountName,
    [string]$SanctionedSourcePrefix = '203.0.113.10/32',
    [ValidateSet('RewriteSource', 'Deny')][string]$RemediationMode = 'RewriteSource',
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$functionProject = Join-Path $repoRoot 'azure-function-enforcer'
$alertTemplate = Join-Path $repoRoot 'iac\azure\nsg-enforcer-alerts.json'
$projectTag = 'MultiCloudServerlessComplianceLab'
$azCommand = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCommand) {
    $fallbackAz = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
    if (Test-Path -LiteralPath $fallbackAz) {
        $azCommand = [pscustomobject]@{ Source = $fallbackAz }
    }
}

$funcCommand = Get-Command func -ErrorAction SilentlyContinue
if (-not $funcCommand) {
    $fallbackFunc = 'C:\Program Files\Microsoft\Azure Functions Core Tools\func.exe'
    if (Test-Path -LiteralPath $fallbackFunc) {
        $funcCommand = [pscustomobject]@{ Source = $fallbackFunc }
    }
}

if (-not $azCommand) {
    throw 'Azure CLI was not found. Install Azure CLI or restart VS Code/PowerShell so az is on PATH.'
}

if (-not $funcCommand) {
    throw 'Azure Functions Core Tools was not found. Install Core Tools or restart VS Code/PowerShell so func is on PATH.'
}

if (-not $SubscriptionId) {
    throw 'Pass -SubscriptionId or set AZURE_SUBSCRIPTION_ID before running this script.'
}

if (-not $TenantId) {
    throw 'Pass -TenantId or set AZURE_TENANT_ID before running this script.'
}

$azDirectory = Split-Path -Parent $azCommand.Source
$funcDirectory = Split-Path -Parent $funcCommand.Source
$env:PATH = "$azDirectory;$funcDirectory;$env:PATH"

function Invoke-AzCli {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $azCommand.Source @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"

    if ($exitCode -ne 0) {
        throw "az $($Arguments -join ' ')`n$text"
    }

    return $text.Trim()
}

function Assert-AzureSubscription {
    $subscriptionJson = Invoke-AzCli -Arguments @(
        'account', 'list',
        '--all',
        '--query', "[?id=='$SubscriptionId'] | [0]",
        '--output', 'json'
    )

    if (-not $subscriptionJson -or $subscriptionJson -eq 'null') {
        throw @"
Azure CLI cannot currently see subscription $SubscriptionId.

Refresh your Azure CLI subscription cache, then rerun this script:

az account clear
az login --tenant $TenantId --use-device-code --subscription $SubscriptionId
az account set --subscription $SubscriptionId
az account show --output table
"@
    }

    return $subscriptionJson | ConvertFrom-Json
}

function Register-ResourceProviders {
    param([Parameter(Mandatory = $true)][string[]]$Namespaces)

    foreach ($namespace in $Namespaces) {
        $state = Invoke-AzCli -Arguments @(
            'provider', 'show',
            '--subscription', $SubscriptionId,
            '--namespace', $namespace,
            '--query', 'registrationState',
            '--output', 'tsv'
        )

        if ($state -ne 'Registered') {
            Write-Host "Registering Azure resource provider $namespace"
            Invoke-AzCli -Arguments @(
                'provider', 'register',
                '--subscription', $SubscriptionId,
                '--namespace', $namespace
            ) | Out-Null
        }
    }

    foreach ($namespace in $Namespaces) {
        Write-Host "Waiting for Azure resource provider $namespace to be Registered"
        for ($attempt = 1; $attempt -le 40; $attempt++) {
            $state = Invoke-AzCli -Arguments @(
                'provider', 'show',
                '--subscription', $SubscriptionId,
                '--namespace', $namespace,
                '--query', 'registrationState',
                '--output', 'tsv'
            )

            if ($state -eq 'Registered') {
                break
            }

            if ($attempt -eq 40) {
                throw "Azure resource provider $namespace did not finish registering. Current state: $state"
            }

            Start-Sleep -Seconds 10
        }
    }
}

function Test-AzureResource {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    try {
        Invoke-AzCli -Arguments $Arguments | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

if (-not (Test-Path -LiteralPath $functionProject)) {
    throw "Function project not found: $functionProject"
}

if (-not (Test-Path -LiteralPath $alertTemplate)) {
    throw "Alert template not found: $alertTemplate"
}

$subscription = Assert-AzureSubscription
$account = Invoke-AzCli -Arguments @('account', 'show', '--query', '{name:name,id:id,tenantId:tenantId}', '--output', 'json') | ConvertFrom-Json
if ($account.id -ne $SubscriptionId -or $account.tenantId -ne $TenantId) {
    Write-Host "Setting Azure subscription context to $SubscriptionId"
}

Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$account = Invoke-AzCli -Arguments @('account', 'show', '--query', '{name:name,id:id,tenantId:tenantId}', '--output', 'json') | ConvertFrom-Json
if ($account.id -ne $SubscriptionId) {
    throw "Azure CLI active subscription is $($account.id), expected $SubscriptionId."
}

$suffix = ($SubscriptionId -replace '-', '').Substring(0, 8).ToLowerInvariant()
if (-not $FunctionAppName) {
    $FunctionAppName = "func-mc-nsg-$suffix"
}

if (-not $StorageAccountName) {
    $StorageAccountName = "stmcfunc$suffix"
}

if ($StorageAccountName.Length -gt 24) {
    throw 'StorageAccountName must be 24 characters or fewer.'
}

Write-Host 'Azure Function enforcer deployment plan'
Write-Host "Subscription:            $SubscriptionId"
Write-Host "Subscription name:       $($subscription.name)"
Write-Host "Tenant:                  $TenantId"
Write-Host "Resource group:          $ResourceGroupName"
Write-Host "Location:                $Location"
Write-Host "Function app:            $FunctionAppName"
Write-Host "Storage account:         $StorageAccountName"
Write-Host "Sanctioned source:       $SanctionedSourcePrefix"
Write-Host "Remediation mode:        $RemediationMode"
Write-Host "Function project folder: $functionProject"

if (-not $Execute) {
    Write-Host ''
    Write-Host 'Dry run only. Re-run with -Execute to deploy Azure resources and publish the Function.'
    return
}

Register-ResourceProviders -Namespaces @(
    'Microsoft.Storage',
    'Microsoft.Web',
    'Microsoft.Insights',
    'Microsoft.Network'
)

Invoke-AzCli -Arguments @(
    'group', 'create',
    '--subscription', $SubscriptionId,
    '--name', $ResourceGroupName,
    '--location', $Location,
    '--tags',
    "Project=$projectTag",
    'LabResource=true',
    'ManagedBy=Codex'
) | Out-Null

$storageExists = Test-AzureResource -Arguments @(
    'storage', 'account', 'show',
    '--subscription', $SubscriptionId,
    '--name', $StorageAccountName,
    '--resource-group', $ResourceGroupName
)

if ($storageExists) {
    Write-Host "Storage account already exists: $StorageAccountName"
}
else {
    Invoke-AzCli -Arguments @(
        'storage', 'account', 'create',
        '--subscription', $SubscriptionId,
        '--name', $StorageAccountName,
        '--resource-group', $ResourceGroupName,
        '--location', $Location,
        '--sku', 'Standard_LRS',
        '--kind', 'StorageV2',
        '--allow-blob-public-access', 'false',
        '--min-tls-version', 'TLS1_2',
        '--tags',
        "Project=$projectTag",
        'LabResource=true',
        'ManagedBy=Codex'
    ) | Out-Null
}

$functionAppExists = Test-AzureResource -Arguments @(
    'functionapp', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $FunctionAppName
)

if ($functionAppExists) {
    Write-Host "Function app already exists: $FunctionAppName"
}
else {
    Invoke-AzCli -Arguments @(
        'functionapp', 'create',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $FunctionAppName,
        '--storage-account', $StorageAccountName,
        '--consumption-plan-location', $Location,
        '--runtime', 'powershell',
        '--runtime-version', '7.4',
        '--functions-version', '4',
        '--os-type', 'Windows',
        '--assign-identity', '[system]',
        '--https-only', 'true',
        '--tags',
        "Project=$projectTag",
        'LabResource=true',
        'ManagedBy=Codex'
    ) | Out-Null
}

$principalId = Invoke-AzCli -Arguments @(
    'functionapp', 'identity', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $FunctionAppName,
    '--query', 'principalId',
    '--output', 'tsv'
)

if (-not $principalId -or $principalId -eq 'null') {
    Write-Host "Assigning system-managed identity to $FunctionAppName"
    Invoke-AzCli -Arguments @(
        'functionapp', 'identity', 'assign',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $FunctionAppName
    ) | Out-Null
}

Invoke-AzCli -Arguments @(
    'functionapp', 'config', 'appsettings', 'set',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $FunctionAppName,
    '--settings',
    "SANCTIONED_SOURCE_PREFIX=$SanctionedSourcePrefix",
    "REMEDIATION_MODE=$RemediationMode",
    'FUNCTIONS_WORKER_RUNTIME_VERSION=7.4',
    'PSWorkerInProcConcurrencyUpperBound=1'
) | Out-Null

$principalId = Invoke-AzCli -Arguments @(
    'functionapp', 'identity', 'show',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $FunctionAppName,
    '--query', 'principalId',
    '--output', 'tsv'
)

$resourceGroupId = Invoke-AzCli -Arguments @(
    'group', 'show',
    '--subscription', $SubscriptionId,
    '--name', $ResourceGroupName,
    '--query', 'id',
    '--output', 'tsv'
)

Write-Host "Assigning Network Contributor to managed identity $principalId scoped to $resourceGroupId"
try {
    Invoke-AzCli -Arguments @(
        'role', 'assignment', 'create',
        '--subscription', $SubscriptionId,
        '--assignee-object-id', $principalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', 'Network Contributor',
        '--scope', $resourceGroupId
    ) | Out-Null
}
catch {
    if ($_.Exception.Message -notmatch 'RoleAssignmentExists') {
        throw
    }
}

Push-Location $functionProject
try {
    & $funcCommand.Source azure functionapp publish $FunctionAppName --powershell --force
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure Functions publish failed.'
    }
}
finally {
    Pop-Location
}

$functionKey = Invoke-AzCli -Arguments @(
    'functionapp', 'function', 'keys', 'list',
    '--subscription', $SubscriptionId,
    '--resource-group', $ResourceGroupName,
    '--name', $FunctionAppName,
    '--function-name', 'EnforceNsgRules',
    '--query', 'default',
    '--output', 'tsv'
)

if (-not $functionKey -or $functionKey -eq 'null') {
    throw 'Could not retrieve the EnforceNsgRules default function key.'
}

$webhookUrl = "https://$FunctionAppName.azurewebsites.net/api/enforce-nsg?code=$functionKey"

$parameterFile = Join-Path $env:TEMP "nsg-enforcer-alerts-$([guid]::NewGuid().ToString()).parameters.json"
$parameterDocument = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        functionWebhookUrl = @{
            value = $webhookUrl
        }
    }
}

try {
    $parameterDocument | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $parameterFile -Encoding UTF8

    Invoke-AzCli -Arguments @(
        'deployment', 'group', 'create',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', 'deploy-nsg-enforcer-alerts',
        '--template-file', $alertTemplate,
        '--parameters', "@$parameterFile"
    ) | Out-Null
}
finally {
    Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Azure Function enforcer deployment complete.'
Write-Host "Function app: $FunctionAppName"
Write-Host "Action group: ag-mc-compliance-nsg-enforcer"
Write-Host "Activity alerts: alert-nsg-security-rule-write, alert-nsg-write"
Write-Host 'Do not commit function keys, webhook URLs, or raw deployment output.'
