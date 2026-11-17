
Write-Host "Step 1"
$binDir = "/home/azureadmin/.bucket-script/bin"
if (-not (Test-Path -LiteralPath $binDir)) {
    [System.IO.Directory]::CreateDirectory($binDir) | Out-Null
}
Write-Host "Step 2"
$sourceDir = "/home/azureadmin/mcp/projects/bucket-script"
$fileName = "bucket-script.ps1"
$srcPath = Join-Path $sourceDir $fileName
$destPath = Join-Path $binDir $fileName
Write-Host "Step 3"
Copy-Item -LiteralPath $srcPath -Destination $destPath -Force
Write-Host "Step 4"
