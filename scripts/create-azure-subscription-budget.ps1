param(
    [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
    [string]$BudgetName = 'lab-subscription-monthly-budget',
    [decimal]$Amount = 25,
    [Parameter(Mandatory = $true)][string[]]$ContactEmails,
    [string]$StartDate = (Get-Date -Day 1 -Format 'yyyy-MM-dd'),
    [string]$EndDate = (Get-Date).AddYears(2).ToString('yyyy-MM-dd')
)

$ErrorActionPreference = 'Stop'

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path = @($machinePath, $userPath, $env:Path) -join ';'

$az = Get-Command az -ErrorAction Stop
$templateFile = Join-Path $PSScriptRoot '..\iac\azure\subscription-budget.json'
$parametersFile = Join-Path ([System.IO.Path]::GetTempPath()) "subscription-budget-$([guid]::NewGuid()).parameters.json"

if (-not $SubscriptionId) {
    throw 'Pass -SubscriptionId or set AZURE_SUBSCRIPTION_ID before running this script.'
}

Write-Host "Setting Azure subscription context to $SubscriptionId"
& $az.Source account set --subscription $SubscriptionId

try {
    $parameters = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
            budgetName = @{ value = $BudgetName }
            amount = @{ value = $Amount }
            startDate = @{ value = $StartDate }
            endDate = @{ value = $EndDate }
            contactEmails = @{ value = $ContactEmails }
        }
    }

    $parameters | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parametersFile -Encoding utf8

    Write-Host "Creating or updating budget '$BudgetName' at subscription scope by ARM deployment."
    & $az.Source deployment sub create `
        --name "deploy-$BudgetName" `
        --location eastus `
        --template-file $templateFile `
        --parameters "@$parametersFile" `
        --output json
}
finally {
    if (Test-Path -LiteralPath $parametersFile) {
        Remove-Item -LiteralPath $parametersFile -Force
    }
}

if ($LASTEXITCODE -ne 0) {
    throw "Azure budget deployment failed. Run az logout, then az login with MFA, and rerun this script."
}

Write-Host ''
Write-Host 'Budget deployment complete. Confirm in Azure Portal under:'
Write-Host "Subscriptions > Multi-Cloud Compliance Lab > Cost Management > Budgets > $BudgetName"
