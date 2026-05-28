param(
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [Parameter(Mandatory = $true)][string]$NetworkSecurityGroupName,
    [int]$Iterations = 25,
    [string]$RuleName = 'lab-open-rdp',
    [string]$OpenSourcePrefix = '0.0.0.0/0',
    [string]$ClosedSourcePrefix = '203.0.113.10/32',
    [switch]$Execute
)

if (-not $Execute) {
    Write-Host 'Dry run only. Re-run with -Execute to modify the NSG.'
}

for ($i = 1; $i -le $Iterations; $i++) {
    $source = if ($i % 2 -eq 0) { $ClosedSourcePrefix } else { $OpenSourcePrefix }
    Write-Host "[$i/$Iterations] $NetworkSecurityGroupName/$RuleName source -> $source"

    if (-not $Execute) {
        continue
    }

    $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $NetworkSecurityGroupName
    $existing = $nsg.SecurityRules | Where-Object { $_.Name -eq $RuleName }

    if ($existing) {
        $existing.SourceAddressPrefix = $source
        $existing.SourceAddressPrefixes = @()
        $nsg | Set-AzNetworkSecurityGroup | Out-Null
    }
    else {
        $nsg |
            Add-AzNetworkSecurityRuleConfig `
                -Name $RuleName `
                -Description 'Lab-only RDP exposure rule for compliance remediation testing.' `
                -Access Allow `
                -Protocol Tcp `
                -Direction Inbound `
                -Priority 120 `
                -SourceAddressPrefix $source `
                -SourcePortRange '*' `
                -DestinationAddressPrefix '*' `
                -DestinationPortRange 3389 |
            Set-AzNetworkSecurityGroup | Out-Null
    }

    Start-Sleep -Seconds 3
}

Write-Host 'Azure chaos loop complete. Check Application Insights traces for POLICY ENFORCED entries.'
