param()

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path = @($machinePath, $userPath, $env:Path) -join ';'

$commands = @(
    @{ Name = 'git'; Purpose = 'version control' },
    @{ Name = 'code'; Purpose = 'Visual Studio Code command line' },
    @{ Name = 'aws'; Purpose = 'AWS CLI and SSO login' },
    @{ Name = 'sam'; Purpose = 'AWS SAM local build/deploy' },
    @{ Name = 'az'; Purpose = 'Azure CLI login and role assignments' },
    @{ Name = 'func'; Purpose = 'Azure Functions Core Tools local run/deploy' },
    @{ Name = 'gh'; Purpose = 'GitHub CLI repository creation/auth' }
)

$results = foreach ($command in $commands) {
    $resolved = Get-Command $command.Name -ErrorAction SilentlyContinue
    if ($resolved) {
        [pscustomobject]@{
            Tool = $command.Name
            Status = 'Installed'
            Purpose = $command.Purpose
            Path = $resolved.Source
        }
    }
    else {
        [pscustomobject]@{
            Tool = $command.Name
            Status = 'Missing'
            Purpose = $command.Purpose
            Path = ''
        }
    }
}

$results | Format-Table -AutoSize

Write-Host ''
Write-Host 'Install missing tools from official sources before deploying cloud resources.'
Write-Host 'Recommended: GitHub CLI, Azure CLI, Azure Functions Core Tools, AWS SAM CLI.'
