param(
    [string]$Profile = 'codex-admin',
    [string]$Region = 'us-east-1',
    [Parameter(Mandatory = $true)][string[]]$BucketNames,
    [int]$Iterations = 25,
    [switch]$Execute
)

if (-not $Execute) {
    Write-Host 'Dry run only. Re-run with -Execute to toggle bucket ACLs.'
}

for ($i = 1; $i -le $Iterations; $i++) {
    foreach ($bucket in $BucketNames) {
        $acl = if ($i % 2 -eq 0) { 'private' } else { 'public-read' }
        Write-Host "[$i/$Iterations] s3://$bucket -> $acl"

        if ($Execute) {
            aws s3api put-bucket-acl `
                --bucket $bucket `
                --acl $acl `
                --profile $Profile `
                --region $Region | Out-Null
        }
    }
}

Write-Host 'AWS chaos loop complete. Check the Lambda CloudWatch log group for COMPLIANCE_SCAN and COMPLIANCE_VIOLATION entries.'
