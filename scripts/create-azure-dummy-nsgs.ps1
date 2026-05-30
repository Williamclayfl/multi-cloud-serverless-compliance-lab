param(
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$TenantId = $env:AZURE_TENANT_ID,
    [string]$ResourceGroupName = 'rg-mc-compliance-lab-eastus',
    [string]$Location = 'eastus',
    [int]$Count = 5,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

$projectTag = 'MultiCloudServerlessComplianceLab'
$basePrefix = '10.61'
$azCommand = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCommand) {
    $fallbackAz = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
    if (Test-Path -LiteralPath $fallbackAz) {
        $azCommand = [pscustomobject]@{ Source = $fallbackAz }
    }
}

if (-not $azCommand) {
    throw 'Azure CLI was not found. Install Azure CLI or restart VS Code/PowerShell so az is on PATH.'
}

if (-not $SubscriptionId) {
    throw 'Pass -SubscriptionId or set AZURE_SUBSCRIPTION_ID before running this script.'
}

if (-not $TenantId) {
    throw 'Pass -TenantId or set AZURE_TENANT_ID before running this script.'
}

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

    Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
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

if ($Count -lt 5) {
    throw 'Count must be at least 5 to satisfy the lab metric.'
}

Write-Host "Azure dummy NSG plan"
Write-Host "Subscription: $SubscriptionId"
Write-Host "Resource group: $ResourceGroupName"
Write-Host "Location:       $Location"
Write-Host "Resource count: $Count VNets + $Count NSGs"

if (-not $Execute) {
    Write-Host ''
    Write-Host 'Dry run only. Re-run with -Execute to create lab resources.'
}

Assert-AzureSubscription

if ($Execute) {
    Register-ResourceProviders -Namespaces @('Microsoft.Network')

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
}

for ($i = 1; $i -le $Count; $i++) {
    $suffix = $i.ToString('00')
    $vnetName = "vnet-mc-compliance-lab-$suffix"
    $nsgName = "nsg-mc-compliance-lab-$suffix"
    $subnetName = "snet-lab-$suffix"
    $addressPrefix = "$basePrefix.$i.0/24"
    $subnetPrefix = "$basePrefix.$i.0/27"
    $port = if ($i % 2 -eq 0) { '22' } else { '3389' }
    $ruleName = if ($port -eq '22') { 'lab-open-ssh' } else { 'lab-open-rdp' }

    Write-Host "[$suffix] $vnetName / $nsgName / $ruleName opens TCP $port from 0.0.0.0/0"

    if (-not $Execute) {
        continue
    }

    Invoke-AzCli -Arguments @(
        'network', 'nsg', 'create',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $nsgName,
        '--location', $Location,
        '--tags',
        "Project=$projectTag",
        'LabResource=true',
        'ComplianceState=IntentionallyNonCompliant'
    ) | Out-Null

    Invoke-AzCli -Arguments @(
        'network', 'nsg', 'rule', 'create',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--nsg-name', $nsgName,
        '--name', $ruleName,
        '--priority', (100 + $i).ToString(),
        '--direction', 'Inbound',
        '--access', 'Allow',
        '--protocol', 'Tcp',
        '--source-address-prefixes', '0.0.0.0/0',
        '--source-port-ranges', '*',
        '--destination-address-prefixes', '*',
        '--destination-port-ranges', $port,
        '--description', 'Lab-only intentionally open admin rule for Azure Function remediation testing.'
    ) | Out-Null

    Invoke-AzCli -Arguments @(
        'network', 'vnet', 'create',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--name', $vnetName,
        '--location', $Location,
        '--address-prefixes', $addressPrefix,
        '--subnet-name', $subnetName,
        '--subnet-prefixes', $subnetPrefix,
        '--network-security-group', $nsgName,
        '--tags',
        "Project=$projectTag",
        'LabResource=true'
    ) | Out-Null
}

Write-Host ''
if ($Execute) {
    Write-Host 'Azure dummy NSGs created. They are intentionally non-compliant until the Function enforcer remediates them.'
}
else {
    Write-Host 'No Azure resources were created.'
}
