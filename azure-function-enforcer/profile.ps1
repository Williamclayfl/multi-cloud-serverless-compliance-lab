if ($env:MSI_SECRET -or $env:IDENTITY_ENDPOINT) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
    Write-Information "Connected to Azure using the Function App managed identity."
}
