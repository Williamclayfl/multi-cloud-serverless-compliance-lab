param(
    [string]$SubscriptionId = 'ee749a4a-0ebf-4154-8c2a-ffd0daaf83f8',
    [string]$BudgetName = 'lab-monthly-budget',
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

Write-Host "Setting Azure subscription context to $SubscriptionId"
& $az.Source account set --subscription $SubscriptionId

$body = @{
    properties = @{
        category = 'Cost'
        amount = $Amount
        timeGrain = 'Monthly'
        timePeriod = @{
            startDate = $StartDate
            endDate = $EndDate
        }
        notifications = @{
            Actual_50_Percent = @{
                enabled = $true
                operator = 'GreaterThanOrEqualTo'
                threshold = 50
                thresholdType = 'Actual'
                contactEmails = $ContactEmails
                contactRoles = @()
                contactGroups = @()
            }
            Actual_80_Percent = @{
                enabled = $true
                operator = 'GreaterThanOrEqualTo'
                threshold = 80
                thresholdType = 'Actual'
                contactEmails = $ContactEmails
                contactRoles = @()
                contactGroups = @()
            }
            Actual_100_Percent = @{
                enabled = $true
                operator = 'GreaterThanOrEqualTo'
                threshold = 100
                thresholdType = 'Actual'
                contactEmails = $ContactEmails
                contactRoles = @()
                contactGroups = @()
            }
            Forecasted_50_Percent = @{
                enabled = $true
                operator = 'GreaterThanOrEqualTo'
                threshold = 50
                thresholdType = 'Forecasted'
                contactEmails = $ContactEmails
                contactRoles = @()
                contactGroups = @()
            }
        }
    }
}

$budgetUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets/$BudgetName`?api-version=2023-05-01"
$bodyJson = $body | ConvertTo-Json -Depth 10

Write-Host "Creating or updating budget '$BudgetName' at subscription scope."
& $az.Source rest --method put --url $budgetUri --body $bodyJson --headers 'Content-Type=application/json' --output json

if ($LASTEXITCODE -ne 0) {
    throw "Azure budget API call failed. Run az logout, then az login with MFA, and rerun this script."
}

Write-Host ''
Write-Host 'Budget deployment complete. Confirm in Azure Portal under:'
Write-Host "Subscriptions > Multi-Cloud Compliance Lab > Cost Management > Budgets > $BudgetName"
