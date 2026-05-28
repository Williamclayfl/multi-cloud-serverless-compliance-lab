using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

function Write-PolicyEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [hashtable]$Fields = @{}
    )

    $payload = @{ message = $Message } + $Fields
    Write-Information ($payload | ConvertTo-Json -Depth 8 -Compress)
}

function Get-AlertBody {
    param($Request)

    if ($Request.Body -is [string]) {
        return $Request.Body | ConvertFrom-Json -Depth 20
    }

    return $Request.Body
}

function Get-NsgIdentityFromResourceId {
    param([Parameter(Mandatory = $true)][string]$ResourceId)

    $pattern = '/resourceGroups/([^/]+)/providers/Microsoft\.Network/networkSecurityGroups/([^/]+)'
    $match = [regex]::Match($ResourceId, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    if (-not $match.Success) {
        return $null
    }

    return @{
        ResourceGroupName = $match.Groups[1].Value
        NetworkSecurityGroupName = $match.Groups[2].Value
    }
}

function Get-AlertTargetResourceIds {
    param($Body)

    $ids = @()

    if ($Body.data.essentials.alertTargetIDs) {
        $ids += @($Body.data.essentials.alertTargetIDs)
    }

    if ($Body.data.alertContext.resourceId) {
        $ids += $Body.data.alertContext.resourceId
    }

    if ($Body.data.alertContext.authorization.scope) {
        $ids += $Body.data.alertContext.authorization.scope
    }

    return $ids | Where-Object { $_ } | Select-Object -Unique
}

function Test-PortCovered {
    param(
        [AllowNull()][object]$PortValues,
        [Parameter(Mandatory = $true)][string[]]$TargetPorts
    )

    foreach ($value in @($PortValues)) {
        if (-not $value) {
            continue
        }

        $text = [string]$value
        if ($text -eq '*') {
            return $true
        }

        if ($TargetPorts -contains $text) {
            return $true
        }

        if ($text -match '^(\d+)-(\d+)$') {
            $start = [int]$matches[1]
            $end = [int]$matches[2]
            foreach ($target in $TargetPorts) {
                $port = [int]$target
                if ($port -ge $start -and $port -le $end) {
                    return $true
                }
            }
        }
    }

    return $false
}

function Test-InternetSource {
    param([AllowNull()][object]$SourceValues)

    $openSources = @('*', '0.0.0.0/0', '::/0', 'Internet', 'Any')

    foreach ($value in @($SourceValues)) {
        if ($openSources -contains ([string]$value)) {
            return $true
        }
    }

    return $false
}

function Get-RuleValues {
    param(
        [Parameter(Mandatory = $true)]$Rule,
        [Parameter(Mandatory = $true)][string]$SingularProperty,
        [Parameter(Mandatory = $true)][string]$PluralProperty
    )

    $values = @()
    if ($Rule.$SingularProperty) {
        $values += $Rule.$SingularProperty
    }
    if ($Rule.$PluralProperty) {
        $values += @($Rule.$PluralProperty)
    }
    return $values
}

try {
    $body = Get-AlertBody -Request $Request
    $targetIds = Get-AlertTargetResourceIds -Body $body
    $sanctionedSourcePrefix = $env:SANCTIONED_SOURCE_PREFIX
    $remediationMode = $env:REMEDIATION_MODE

    if (-not $sanctionedSourcePrefix) {
        $sanctionedSourcePrefix = '203.0.113.10/32'
    }

    if (-not $remediationMode) {
        $remediationMode = 'RewriteSource'
    }

    $nsgTargets = foreach ($targetId in $targetIds) {
        Get-NsgIdentityFromResourceId -ResourceId $targetId
    }

    $nsgTargets = $nsgTargets | Where-Object { $_ } | Sort-Object ResourceGroupName, NetworkSecurityGroupName -Unique

    if (-not $nsgTargets) {
        Write-PolicyEvent -Message 'POLICY_NO_TARGET' -Fields @{
            reason = 'No Network Security Group resource ID was found in the alert payload.'
        }

        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Accepted
            Body = @{ status = 'no_target' } | ConvertTo-Json
        })
        return
    }

    $enforcedRules = @()

    foreach ($target in $nsgTargets) {
        $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $target.ResourceGroupName -Name $target.NetworkSecurityGroupName
        $changed = $false

        foreach ($rule in $nsg.SecurityRules) {
            $ports = Get-RuleValues -Rule $rule -SingularProperty 'DestinationPortRange' -PluralProperty 'DestinationPortRanges'
            $sources = Get-RuleValues -Rule $rule -SingularProperty 'SourceAddressPrefix' -PluralProperty 'SourceAddressPrefixes'

            $isOffendingRule = $rule.Direction -eq 'Inbound' -and
                $rule.Access -eq 'Allow' -and
                (Test-PortCovered -PortValues $ports -TargetPorts @('22', '3389')) -and
                (Test-InternetSource -SourceValues $sources)

            if (-not $isOffendingRule) {
                continue
            }

            if ($remediationMode -eq 'Deny') {
                $rule.Access = 'Deny'
            }
            else {
                $rule.SourceAddressPrefix = $sanctionedSourcePrefix
                $rule.SourceAddressPrefixes = @()
            }

            $changed = $true
            $enforcedRules += @{
                resourceGroupName = $target.ResourceGroupName
                networkSecurityGroupName = $target.NetworkSecurityGroupName
                ruleName = $rule.Name
                remediationMode = $remediationMode
                sanctionedSourcePrefix = $sanctionedSourcePrefix
            }
        }

        if ($changed) {
            $nsg | Set-AzNetworkSecurityGroup | Out-Null
        }
    }

    foreach ($enforcedRule in $enforcedRules) {
        Write-PolicyEvent -Message 'POLICY ENFORCED' -Fields $enforcedRule
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = @{
            status = 'completed'
            enforcedRuleCount = $enforcedRules.Count
            enforcedRules = $enforcedRules
        } | ConvertTo-Json -Depth 8
    })
}
catch {
    Write-PolicyEvent -Message 'POLICY_ERROR' -Fields @{
        error = $_.Exception.Message
        stack = $_.ScriptStackTrace
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = @{
            status = 'error'
            error = $_.Exception.Message
        } | ConvertTo-Json
    })
}
