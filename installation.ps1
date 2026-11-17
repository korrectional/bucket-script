#Requires -Version 5.1
<#
.SYNOPSIS
    Installer script for bucket-script Windows CLI.

.DESCRIPTION
    Installs bucket-script.ps1, bucket-script.cmd, and bucket-script.bat into the user's
    local directory ($env:USERPROFILE\.bucket-script\bin), permanently adds the directory
    to the Windows User PATH, updates the current session PATH, and configures the API key
    in $env:USERPROFILE\.bucket-script\config.json.

.PARAMETER ApiKey
    Optional BUCKET_API_KEY to configure during installation. If omitted, prompts interactively.

.PARAMETER BaseUrl
    Base URL for Bucketloader service (default: https://kanevskyy.dev/bucket).

.PARAMETER InstallDir
    Custom installation directory for the binaries (defaults to $env:USERPROFILE\.bucket-script\bin).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\installation.ps1
    powershell -ExecutionPolicy Bypass -File .\installation.ps1 -ApiKey "your-api-key"
#>

[CmdletBinding()]
param(
    [Alias("key")]
    [string]$ApiKey,

    [Alias("url")]
    [string]$BaseUrl = "https://kanevskyy.dev/bucket",

    [string]$InstallDir,

    [switch]$Force
)

function Mask-ApiKey([string]$key) {
    if ([string]::IsNullOrEmpty($key)) { return "(none)" }
    if ($key.Length -le 8) { return "********" }
    $prefix = $key.Substring(0, 4)
    $suffix = $key.Substring($key.Length - 4, 4)
    return "$prefix" + ("*" * ($key.Length - 8)) + "$suffix"
}

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "  Bucketloader CLI Installer (bucket-script)" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

# 1. Determine directories
$userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$bucketHome = Join-Path $userHome ".bucket-script"
$binDir = if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
    [System.IO.Path]::GetFullPath($InstallDir)
} else {
    Join-Path $bucketHome "bin"
}
$configFile = Join-Path $bucketHome "config.json"

Write-Host ("Target installation directory: " + $binDir) -ForegroundColor Gray

# 2. Ensure directories exist
if (-not (Test-Path -LiteralPath $binDir)) {
    [System.IO.Directory]::CreateDirectory($binDir) | Out-Null
}
if (-not (Test-Path -LiteralPath $bucketHome)) {
    [System.IO.Directory]::CreateDirectory($bucketHome) | Out-Null
}

# 3. Locate source files and copy into bin directory
$sourceDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($sourceDir)) {
    $sourceDir = (Get-Location).Path
}

$filesToCopy = @("bucket-script.ps1", "bucket-script.cmd", "bucket-script.bat")
$copiedCount = 0

foreach ($fileName in $filesToCopy) {
    $srcPath = Join-Path $sourceDir $fileName
    if (Test-Path -LiteralPath $srcPath) {
        $destPath = Join-Path $binDir $fileName
        Copy-Item -LiteralPath $srcPath -Destination $destPath -Force
        Write-Host ("  [+] Copied: " + $fileName) -ForegroundColor Green
        $copiedCount++
    } else {
        Write-Host ("  [-] Source file not found: " + $srcPath) -ForegroundColor Yellow
    }
}

if ($copiedCount -eq 0) {
    Write-Host -ForegroundColor Red "Error: No CLI script files were found to install in '$sourceDir'."
    exit 1
}

# 4. Permanently add binDir to Windows User PATH environment variable
$isWindows = ($IsWindows -eq $true) -or ([System.Environment]::OSVersion.Platform -match "Win")
if ($isWindows) {
    try {
        $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        $pathSegments = if ($userPath) { $userPath -split ';' } else { @() }
        $normalizedBin = $binDir.TrimEnd('\', '/')
        $alreadyInPath = $false

        foreach ($seg in $pathSegments) {
            if ($seg.Trim().TrimEnd('\', '/') -ieq $normalizedBin) {
                $alreadyInPath = $true
                break
            }
        }

        if (-not $alreadyInPath) {
            $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $binDir } else { "$userPath;$binDir" }
            [System.Environment]::SetEnvironmentVariable("Path", $newPath, "User")
            Write-Host "  [+] Permanently added to Windows User PATH: $binDir" -ForegroundColor Green
        } else {
            Write-Host "  [*] Already present in Windows User PATH: $binDir" -ForegroundColor Gray
        }
    } catch {
        Write-Host -ForegroundColor Yellow ("  [!] Warning: Could not update Windows User PATH: " + $_.Exception.Message)
    }
}

# Update current session PATH
$sep = [System.IO.Path]::PathSeparator
$currentSessionPaths = $env:PATH -split $sep
$normalizedBin = $binDir.TrimEnd('\', '/')
$inSession = $false

foreach ($seg in $currentSessionPaths) {
    if ($seg.Trim().TrimEnd('\', '/') -ieq $normalizedBin) {
        $inSession = $true
        break
    }
}

if (-not $inSession) {
    $env:PATH = "$env:PATH$sep$binDir"
    Write-Host "  [+] Updated current session PATH." -ForegroundColor Green
}

# 5. Configure API Key and Base URL
$existingKey = ""
$existingUrl = $BaseUrl.TrimEnd('/')

if (Test-Path -LiteralPath $configFile) {
    try {
        $existingCfg = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
        if ($existingCfg.api_key) { $existingKey = [string]$existingCfg.api_key }
        if ($existingCfg.base_url) { $existingUrl = [string]$existingCfg.base_url }
    } catch { }
}

$finalKey = $ApiKey
if ([string]::IsNullOrWhiteSpace($finalKey)) {
    if ($existingKey) {
        Write-Host ""
        Write-Host ("  Existing configuration found at: " + $configFile) -ForegroundColor Gray
        $choice = Read-Host ("  Keep existing API key (" + (Mask-ApiKey $existingKey) + ")? [Y/n] or enter new key")
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -ieq "y" -or $choice -ieq "yes") {
            $finalKey = $existingKey
        } else {
            $finalKey = $choice.Trim()
        }
    } elseif ($env:BUCKET_API_KEY) {
        $finalKey = $env:BUCKET_API_KEY.Trim()
        Write-Host "  Detected BUCKET_API_KEY from environment." -ForegroundColor Gray
    } else {
        Write-Host ""
        Write-Host "  BUCKET_API_KEY setup:" -ForegroundColor Yellow
        $entered = Read-Host "  Enter your BUCKET_API_KEY (press Enter to skip for now)"
        if (-not [string]::IsNullOrWhiteSpace($entered)) {
            $finalKey = $entered.Trim()
        }
    }
}

$finalUrl = if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl.Trim().TrimEnd('/') } else { "https://kanevskyy.dev/bucket" }

$configData = @{
    api_key  = if ($finalKey) { $finalKey } else { "" }
    base_url = $finalUrl
}
$configJson = $configData | ConvertTo-Json
Set-Content -LiteralPath $configFile -Value $configJson -Encoding UTF8

Write-Host "  [+] Configuration saved to: $configFile" -ForegroundColor Green

# 6. Installation summary
Write-Host ""
Write-Host "================================================================================" -ForegroundColor Green
Write-Host "  Bucketloader CLI (bucket-script) Installed Successfully!" -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Green
Write-Host ("  Binary Directory:   " + $binDir)
Write-Host ("  Config File:        " + $configFile)
Write-Host ("  Base URL:           " + $finalUrl)
Write-Host ("  API Key:            " + $(if ($finalKey) { Mask-ApiKey $finalKey } else { "(not set - run 'bucket-script config --api-key <key>')"}))
Write-Host ""
Write-Host "You can now run 'bucket-script' directly anywhere from Command Prompt or PowerShell:" -ForegroundColor Cyan
Write-Host "  bucket-script health" -ForegroundColor Yellow
Write-Host "  bucket-script help" -ForegroundColor Yellow
Write-Host "  bucket-script list" -ForegroundColor Yellow
Write-Host "  bucket-script <path-to-file>" -ForegroundColor Yellow
Write-Host "================================================================================" -ForegroundColor Green
Write-Host ""
