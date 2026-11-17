#Requires -Version 5.1
<#
.SYNOPSIS
    bucket-script - Production-grade Windows PowerShell CLI for Bucketloader (Google Drive backend).

.DESCRIPTION
    Upload, download, list, delete, and check health of files hosted on Bucketloader
    via Google Drive backend. Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
    bucket-script health
    bucket-script config --api-key <your-api-key>
    bucket-script myfile.png
    bucket-script upload ./data/report.pdf --overwrite
    bucket-script upload-text "hello world" --name notes.txt
    bucket-script list
    bucket-script download notes.txt
    bucket-script download 1BSAxYwSDzswGNLxWy69m1aoYjDvVII0w --out C:\Downloads\backup.zip
    bucket-script delete notes.txt
#>

[CmdletBinding()]
param()

# Ensure TLS 1.2 is enabled for older Windows PowerShell 5.1 environments
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
} catch {
    # Ignore if unsupported on non-Windows / modern .NET
}

# Ensure System.Net.Http is loaded
try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
} catch {
    Write-Host -ForegroundColor Red "Error: Failed to load System.Net.Http assembly."
    exit 1
}

# ------------------------------------------------------------------------------
# Helper Functions: Formatting & Content Types
# ------------------------------------------------------------------------------

function Format-FileSize([long]$bytes) {
    if ($bytes -le 0) { return "0 B" }
    if ($bytes -lt 1024) { return "$bytes B" }
    if ($bytes -lt 1048576) { return ("{0:N2} KB" -f ($bytes / 1KB)) }
    if ($bytes -lt 1073741824) { return ("{0:N2} MB" -f ($bytes / 1MB)) }
    return ("{0:N2} GB" -f ($bytes / 1GB))
}

function Get-ContentType([string]$filePath) {
    $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
    $mimeTypes = @{
        ".txt"   = "text/plain"
        ".html"  = "text/html"
        ".htm"   = "text/html"
        ".css"   = "text/css"
        ".js"    = "application/javascript"
        ".json"  = "application/json"
        ".xml"   = "application/xml"
        ".csv"   = "text/csv"
        ".md"    = "text/markdown"
        ".png"   = "image/png"
        ".jpg"   = "image/jpeg"
        ".jpeg"  = "image/jpeg"
        ".gif"   = "image/gif"
        ".svg"   = "image/svg+xml"
        ".webp"  = "image/webp"
        ".ico"   = "image/x-icon"
        ".pdf"   = "application/pdf"
        ".zip"   = "application/zip"
        ".tar"   = "application/x-tar"
        ".gz"    = "application/gzip"
        ".7z"    = "application/x-7z-compressed"
        ".mp3"   = "audio/mpeg"
        ".wav"   = "audio/wav"
        ".mp4"   = "video/mp4"
        ".mov"   = "video/quicktime"
        ".webm"  = "video/webm"
        ".ps1"   = "text/plain"
        ".cmd"   = "text/plain"
        ".bat"   = "text/plain"
        ".sh"    = "text/plain"
        ".py"    = "text/plain"
        ".yml"   = "application/x-yaml"
        ".yaml"  = "application/x-yaml"
    }
    if ($mimeTypes.ContainsKey($ext)) {
        return $mimeTypes[$ext]
    }
    return "application/octet-stream"
}

function Mask-ApiKey([string]$key) {
    if ([string]::IsNullOrEmpty($key)) { return "(none)" }
    if ($key.Length -le 8) { return "********" }
    $prefix = $key.Substring(0, 4)
    $suffix = $key.Substring($key.Length - 4, 4)
    return "$prefix" + ("*" * ($key.Length - 8)) + "$suffix"
}

# ------------------------------------------------------------------------------
# Configuration Resolution
# ------------------------------------------------------------------------------

function Get-ConfigPaths {
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    $configDir = Join-Path $userHome ".bucket-script"
    $configFile = Join-Path $configDir "config.json"
    return @{
        Dir  = $configDir
        File = $configFile
    }
}

function Load-AppConfig {
    $paths = Get-ConfigPaths
    $config = @{
        ApiKey  = ""
        BaseUrl = "https://kanevskyy.dev/bucket"
    }

    # 1. Read from config file if exists
    if (Test-Path -LiteralPath $paths.File) {
        try {
            $raw = Get-Content -LiteralPath $paths.File -Raw -ErrorAction Stop
            $parsed = $raw | ConvertFrom-Json
            if ($parsed.api_key) { $config.ApiKey = [string]$parsed.api_key }
            elseif ($parsed.apiKey) { $config.ApiKey = [string]$parsed.apiKey }
            elseif ($parsed.BUCKET_API_KEY) { $config.ApiKey = [string]$parsed.BUCKET_API_KEY }

            if ($parsed.base_url) { $config.BaseUrl = [string]$parsed.base_url }
            elseif ($parsed.baseUrl) { $config.BaseUrl = [string]$parsed.baseUrl }
            elseif ($parsed.BUCKET_BASE_URL) { $config.BaseUrl = [string]$parsed.BUCKET_BASE_URL }
        } catch {
            # Ignore corrupted config file, fallback to defaults/env
        }
    }

    # 2. Environment variables override config file
    if ($env:BUCKET_BASE_URL) {
        $config.BaseUrl = $env:BUCKET_BASE_URL
    }
    if ($env:BUCKET_API_KEY) {
        $config.ApiKey = $env:BUCKET_API_KEY
    }

    $config.BaseUrl = $config.BaseUrl.TrimEnd('/')
    return $config
}

function Save-AppConfig([string]$apiKey, [string]$baseUrl) {
    $paths = Get-ConfigPaths
    if (-not (Test-Path -LiteralPath $paths.Dir)) {
        [System.IO.Directory]::CreateDirectory($paths.Dir) | Out-Null
    }

    $current = Load-AppConfig
    $finalKey = if (-not [string]::IsNullOrWhiteSpace($apiKey)) { $apiKey.Trim() } else { $current.ApiKey }
    $finalUrl = if (-not [string]::IsNullOrWhiteSpace($baseUrl)) { $baseUrl.Trim().TrimEnd('/') } else { $current.BaseUrl }

    $data = @{
        api_key  = $finalKey
        base_url = $finalUrl
    }
    $json = $data | ConvertTo-Json
    Set-Content -LiteralPath $paths.File -Value $json -Encoding UTF8

    Write-Host ""
    Write-Host "Configuration saved successfully:" -ForegroundColor Green
    Write-Host ("  Config File: " + $paths.File) -ForegroundColor Gray
    Write-Host ("  Base URL:    " + $finalUrl)
    Write-Host ("  API Key:     " + (Mask-ApiKey $finalKey))
    Write-Host ""
}

# ------------------------------------------------------------------------------
# HTTP Client Factory
# ------------------------------------------------------------------------------

function Create-HttpClient([string]$apiKey) {
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [System.TimeSpan]::FromMinutes(10) # 10 minute timeout for large uploads/downloads
    if (-not [string]::IsNullOrEmpty($apiKey)) {
        $client.DefaultRequestHeaders.Add("X-API-Key", $apiKey)
    }
    return $client
}

function Handle-HttpError([System.Net.Http.HttpResponseMessage]$response, [string]$actionDesc) {
    $statusInt = [int]$response.StatusCode
    $statusText = $response.StatusCode.ToString()
    $errBody = ""
    try {
        $errBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $errJson = $errBody | ConvertFrom-Json
        if ($errJson.detail) {
            $errBody = $errJson.detail
        }
    } catch { }

    Write-Host ""
    Write-Host ("Error during " + $actionDesc + " [" + $statusInt + " " + $statusText + "]:") -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($errBody)) {
        Write-Host ("  " + $errBody) -ForegroundColor Red
    }
    if ($statusInt -eq 401) {
        Write-Host "  -> Please check your BUCKET_API_KEY with 'bucket-script config --api-key <key>'." -ForegroundColor Yellow
    }
    Write-Host ""
}

# ------------------------------------------------------------------------------
# Command Line Argument Parser
# ------------------------------------------------------------------------------

function Parse-CommandLineArgs($rawArgs) {
    $options = @{
        Command    = ""
        Target     = ""
        Name       = ""
        Out        = ""
        Overwrite  = $false
        ApiKey     = ""
        Url        = ""
        Subfolder  = ""
        Positional = [System.Collections.Generic.List[string]]::new()
    }

    $i = 0
    while ($i -lt $rawArgs.Count) {
        $arg = [string]$rawArgs[$i]
        if ($arg -match '^(?:--|-)(name|n)$') {
            $i++
            if ($i -lt $rawArgs.Count) { $options.Name = [string]$rawArgs[$i] }
        }
        elseif ($arg -match '^(?:--|-)(name|n)=(.*)$') {
            $options.Name = $matches[2]
        }
        elseif ($arg -match '^(?:--|-)(out|output|o)$') {
            $i++
            if ($i -lt $rawArgs.Count) { $options.Out = [string]$rawArgs[$i] }
        }
        elseif ($arg -match '^(?:--|-)(out|output|o)=(.*)$') {
            $options.Out = $matches[2]
        }
        elseif ($arg -match '^(?:--|-)(overwrite|force|f)$') {
            $options.Overwrite = $true
        }
        elseif ($arg -match '^(?:--|-)(api-key|apikey|key)$') {
            $i++
            if ($i -lt $rawArgs.Count) { $options.ApiKey = [string]$rawArgs[$i] }
        }
        elseif ($arg -match '^(?:--|-)(api-key|apikey|key)=(.*)$') {
            $options.ApiKey = $matches[2]
        }
        elseif ($arg -match '^(?:--|-)(url|base-url|baseurl)$') {
            $i++
            if ($i -lt $rawArgs.Count) { $options.Url = [string]$rawArgs[$i] }
        }
        elseif ($arg -match '^(?:--|-)(url|base-url|baseurl)=(.*)$') {
            $options.Url = $matches[2]
        }
        elseif ($arg -match '^(?:--|-)(subfolder|folder)$') {
            $i++
            if ($i -lt $rawArgs.Count) { $options.Subfolder = [string]$rawArgs[$i] }
        }
        elseif ($arg -match '^(?:--|-)(subfolder|folder)=(.*)$') {
            $options.Subfolder = $matches[2]
        }
        elseif ($arg -match '^(?:--|-)(help|h|\?)$' -or $arg -eq '/?') {
            $options.Command = "help"
        }
        else {
            $options.Positional.Add($arg)
        }
        $i++
    }

    $knownCommands = @(
        "upload", "upload-text", "list", "ls", "download", "get", "pull",
        "delete", "rm", "del", "health", "status", "config", "help"
    )

    if ($options.Command -ne "help") {
        if ($options.Positional.Count -eq 0) {
            $options.Command = "help"
        } else {
            $first = [string]$options.Positional[0]
            $firstLower = $first.ToLowerInvariant()
            if ($knownCommands -contains $firstLower) {
                $options.Command = $firstLower
                if ($options.Positional.Count -gt 1) {
                    if ($options.Command -eq "upload-text") {
                        # Join all positional tokens after command as the text body
                        $textTokens = @()
                        for ($idx = 1; $idx -lt $options.Positional.Count; $idx++) {
                            $textTokens += $options.Positional[$idx]
                        }
                        $options.Target = $textTokens -join " "
                    } else {
                        $options.Target = [string]$options.Positional[1]
                    }
                }
            }
            # Shorthand invocation: if the first positional argument is an existing local file
            elseif (Test-Path -LiteralPath $first -PathType Leaf) {
                $options.Command = "upload"
                $options.Target = $first
            }
            else {
                $options.Command = "unknown"
                $options.Target = $first
            }
        }
    }

    return $options
}

# ------------------------------------------------------------------------------
# Subcommand Implementations
# ------------------------------------------------------------------------------

function Show-Help {
    Write-Host @"
================================================================================
  bucket-script - CLI Client for Google Drive Bucketloader
================================================================================

USAGE:
  bucket-script <command> [arguments] [options]
  bucket-script <path-to-local-file> [--name <name>] [--overwrite]   (shorthand)

COMMANDS:
  upload <path-to-file>       Upload a local file to the bucket folder.
                              Options: [--name <custom-name>] [--overwrite] [--subfolder <folder>]

  upload-text <content>       Upload text content directly as a file.
                              Required: --name <filename>
                              Options: [--overwrite] [--subfolder <folder>]

  list (or ls)                List stored files in the bucket.
                              Options: [--subfolder <folder>]

  download <id-or-name>       Download a file by file ID or vanity filename.
                              Aliases: get, pull
                              Options: [--out <destination-path>]

  delete <id-or-name>         Delete a file by ID or vanity filename.
                              Aliases: rm, del

  health                      Check server health, Google Drive auth, & folder status.
                              Aliases: status

  config                      Save credentials and base URL to user config file.
                              Options: --api-key <key> [--url <base-url>]
                              (Config stored at: `$env:USERPROFILE\.bucket-script\config.json)

  help                        Display this help manual.

OPTIONS:
  --name, -n <string>         Custom remote filename for upload.
  --overwrite, -f             Overwrite remote file if it already exists.
  --out, -o <path>            Destination file path or directory for download.
  --subfolder <string>        Target subfolder inside the bucket folder.
  --api-key, --key <string>   API key for authentication.
  --url <string>              Bucketloader base URL (default: https://kanevskyy.dev/bucket).

EXAMPLES:
  # Check service status
  bucket-script health

  # Configure credentials once
  bucket-script config --api-key your-secret-api-key

  # Shorthand upload: drop any local file path directly
  bucket-script ./render.png --overwrite

  # Upload with custom remote name and subfolder
  bucket-script upload ./bundle.zip --name "release-2.0.zip" --subfolder "releases"

  # Upload raw text directly
  bucket-script upload-text "Build 142 passed at $(Get-Date)" --name "logs/build.log"

  # List files
  bucket-script list

  # Download by filename or by Google Drive file ID
  bucket-script download release-2.0.zip
  bucket-script download 1BSAxYwSDzswGNLxWy69m1aoYjDvVII0w --out C:\Backups\data.zip

  # Delete a file
  bucket-script delete release-2.0.zip

================================================================================
"@
}

function Invoke-Health($cfg, $opts) {
    $baseUrl = if ($opts.Url) { $opts.Url.TrimEnd('/') } else { $cfg.BaseUrl }
    $url = "$baseUrl/health"

    $client = Create-HttpClient ""
    try {
        $response = $client.GetAsync($url).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            Handle-HttpError $response "health check"
            exit 1
        }

        $jsonStr = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $health = $jsonStr | ConvertFrom-Json

        Write-Host ""
        Write-Host "====================================================" -ForegroundColor Cyan
        Write-Host "  Bucketloader Service Health" -ForegroundColor Cyan
        Write-Host "====================================================" -ForegroundColor Cyan
        Write-Host ("  Endpoint:            " + $url) -ForegroundColor Gray
        Write-Host ("  Status:              " + $health.status) -ForegroundColor $(if ($health.status -eq 'ok') { "Green" } else { "Yellow" })
        Write-Host ("  Drive Authenticated: " + $health.drive_authenticated) -ForegroundColor $(if ($health.drive_authenticated) { "Green" } else { "Red" })
        Write-Host ("  Credentials Config:  " + $health.has_credentials) -ForegroundColor $(if ($health.has_credentials) { "Green" } else { "Red" })
        Write-Host ("  Bucket Folder ID:    " + $(if ($health.bucket_folder_id) { $health.bucket_folder_id } else { "(not set)" }))
        Write-Host "====================================================" -ForegroundColor Cyan

        if (-not $health.drive_authenticated) {
            Write-Host ""
            Write-Host "  [!] Google Drive is not authenticated." -ForegroundColor Yellow
            Write-Host ("      Visit " + $baseUrl + "/auth/url to complete OAuth setup.") -ForegroundColor Yellow
        }
        Write-Host ""
    } catch {
        Write-Host -ForegroundColor Red ("Error connecting to " + $url + ": " + $_.Exception.Message)
        exit 1
    } finally {
        $client.Dispose()
    }
}

function Invoke-Config($cfg, $opts) {
    $key = $opts.ApiKey
    if ([string]::IsNullOrWhiteSpace($key) -and -not [string]::IsNullOrWhiteSpace($opts.Target)) {
        $key = $opts.Target
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Host ""
        Write-Host "Current API Key: " -NoNewline
        Write-Host (Mask-ApiKey $cfg.ApiKey) -ForegroundColor Yellow
        Write-Host "Current Base URL: " -NoNewline
        Write-Host $cfg.BaseUrl -ForegroundColor Cyan
        Write-Host ""
        $key = Read-Host "Enter new BUCKET_API_KEY (press Enter to keep current)"
        if ([string]::IsNullOrWhiteSpace($key)) {
            $key = $cfg.ApiKey
        }
    }

    $url = if (-not [string]::IsNullOrWhiteSpace($opts.Url)) { $opts.Url } else { $cfg.BaseUrl }
    Save-AppConfig $key $url
}

function Ensure-ApiKey($cfg, $opts) {
    $key = if (-not [string]::IsNullOrWhiteSpace($opts.ApiKey)) {
        $opts.ApiKey.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($cfg.ApiKey)) {
        $cfg.ApiKey.Trim()
    } else {
        ""
    }

    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Host ""
        Write-Host "Error: No BUCKET_API_KEY configured." -ForegroundColor Red
        Write-Host "Please set your API key by running:" -ForegroundColor Yellow
        Write-Host "  bucket-script config --api-key <your-api-key>" -ForegroundColor Cyan
        Write-Host "Or by setting the BUCKET_API_KEY environment variable:" -ForegroundColor Yellow
        Write-Host "  `$env:BUCKET_API_KEY = '<your-api-key>'" -ForegroundColor Cyan
        Write-Host ""
        exit 1
    }
    return $key
}

function Invoke-UploadFile($cfg, $opts) {
    $apiKey = Ensure-ApiKey $cfg $opts
    $baseUrl = if ($opts.Url) { $opts.Url.TrimEnd('/') } else { $cfg.BaseUrl }

    $target = $opts.Target
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Host -ForegroundColor Red "Error: File path is required for upload. Usage: bucket-script upload <path-to-file>"
        exit 1
    }

    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        Write-Host -ForegroundColor Red ("Error: Local file not found: " + $target)
        exit 1
    }

    $fullPath = [System.IO.Path]::GetFullPath($target)
    $remoteFileName = if (-not [string]::IsNullOrWhiteSpace($opts.Name)) {
        $opts.Name.Trim()
    } else {
        [System.IO.Path]::GetFileName($fullPath)
    }

    $fileSize = (Get-Item -LiteralPath $fullPath).Length
    $mimeType = Get-ContentType $remoteFileName

    Write-Host ("Uploading '" + [System.IO.Path]::GetFileName($fullPath) + "' (" + (Format-FileSize $fileSize) + ") as '" + $remoteFileName + "'...") -ForegroundColor Cyan

    $client = Create-HttpClient $apiKey
    $form = [System.Net.Http.MultipartFormDataContent]::new()
    $fileStream = $null

    try {
        $fileStream = [System.IO.File]::OpenRead($fullPath)
        $streamContent = [System.Net.Http.StreamContent]::new($fileStream)
        $streamContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($mimeType)
        $form.Add($streamContent, "file", $remoteFileName)

        $overwriteVal = if ($opts.Overwrite) { "true" } else { "false" }
        $form.Add([System.Net.Http.StringContent]::new($overwriteVal), "overwrite")

        if (-not [string]::IsNullOrWhiteSpace($opts.Subfolder)) {
            $form.Add([System.Net.Http.StringContent]::new($opts.Subfolder.Trim()), "subfolder")
        }

        $url = "$baseUrl/upload"
        $response = $client.PostAsync($url, $form).GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            Handle-HttpError $response "upload"
            exit 1
        }

        $respBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $meta = $respBody | ConvertFrom-Json

        Write-Host ""
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host "  Upload Successful" -ForegroundColor Green
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host ("  File ID:     " + $meta.id)
        Write-Host ("  Name:        " + $meta.name)
        Write-Host ("  Size:        " + (Format-FileSize ([long]$meta.size)) + " (" + $meta.size + " bytes)")
        Write-Host ("  MIME Type:   " + $meta.mimeType)
        if ($meta.subfolder) {
            Write-Host ("  Subfolder:   " + $meta.subfolder)
        }
        Write-Host ("  Direct URL:  " + $baseUrl + "/files/" + $meta.id) -ForegroundColor Cyan
        Write-Host ("  Raw URL:     " + $baseUrl + $(if ($meta.raw_path) { $meta.raw_path } else { "/raw/" + $meta.name })) -ForegroundColor Cyan
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host ""
    } catch {
        Write-Host -ForegroundColor Red ("Error uploading file: " + $_.Exception.Message)
        exit 1
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($form) { $form.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Invoke-UploadText($cfg, $opts) {
    $apiKey = Ensure-ApiKey $cfg $opts
    $baseUrl = if ($opts.Url) { $opts.Url.TrimEnd('/') } else { $cfg.BaseUrl }

    if ([string]::IsNullOrWhiteSpace($opts.Name)) {
        Write-Host -ForegroundColor Red "Error: --name <filename> is required for upload-text."
        Write-Host "Usage: bucket-script upload-text <text> --name <filename> [--overwrite]" -ForegroundColor Yellow
        exit 1
    }

    $textContent = $opts.Target
    if ($null -eq $textContent) { $textContent = "" }
    $remoteFileName = $opts.Name.Trim()
    $mimeType = Get-ContentType $remoteFileName

    Write-Host ("Uploading text (" + $textContent.Length + " chars) as '" + $remoteFileName + "'...") -ForegroundColor Cyan

    $client = Create-HttpClient $apiKey
    $form = [System.Net.Http.MultipartFormDataContent]::new()

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($textContent)
        $byteContent = [System.Net.Http.ByteArrayContent]::new($bytes)
        $byteContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($mimeType)
        $form.Add($byteContent, "file", $remoteFileName)

        $overwriteVal = if ($opts.Overwrite) { "true" } else { "false" }
        $form.Add([System.Net.Http.StringContent]::new($overwriteVal), "overwrite")

        if (-not [string]::IsNullOrWhiteSpace($opts.Subfolder)) {
            $form.Add([System.Net.Http.StringContent]::new($opts.Subfolder.Trim()), "subfolder")
        }

        $url = "$baseUrl/upload"
        $response = $client.PostAsync($url, $form).GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            Handle-HttpError $response "upload-text"
            exit 1
        }

        $respBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $meta = $respBody | ConvertFrom-Json

        Write-Host ""
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host "  Text Upload Successful" -ForegroundColor Green
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host ("  File ID:     " + $meta.id)
        Write-Host ("  Name:        " + $meta.name)
        Write-Host ("  Size:        " + (Format-FileSize ([long]$meta.size)) + " (" + $meta.size + " bytes)")
        Write-Host ("  MIME Type:   " + $meta.mimeType)
        Write-Host ("  Direct URL:  " + $baseUrl + "/files/" + $meta.id) -ForegroundColor Cyan
        Write-Host ("  Raw URL:     " + $baseUrl + $(if ($meta.raw_path) { $meta.raw_path } else { "/raw/" + $meta.name })) -ForegroundColor Cyan
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host ""
    } catch {
        Write-Host -ForegroundColor Red ("Error uploading text: " + $_.Exception.Message)
        exit 1
    } finally {
        if ($form) { $form.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Invoke-List($cfg, $opts) {
    $apiKey = Ensure-ApiKey $cfg $opts
    $baseUrl = if ($opts.Url) { $opts.Url.TrimEnd('/') } else { $cfg.BaseUrl }

    $url = "$baseUrl/files"
    if (-not [string]::IsNullOrWhiteSpace($opts.Subfolder)) {
        $encodedSub = [System.Uri]::EscapeDataString($opts.Subfolder.Trim())
        $url = "$url?subfolder=$encodedSub"
    }

    $client = Create-HttpClient $apiKey
    try {
        $response = $client.GetAsync($url).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            Handle-HttpError $response "listing files"
            exit 1
        }

        $jsonStr = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $files = $jsonStr | ConvertFrom-Json

        if (-not $files -or $files.Count -eq 0) {
            Write-Host ""
            Write-Host "No files found in bucket." -ForegroundColor Yellow
            Write-Host ""
            return
        }

        $tableItems = foreach ($f in $files) {
            $modTime = "-"
            if ($f.modifiedTime) {
                try {
                    $modTime = [DateTime]::Parse($f.modifiedTime).ToString("yyyy-MM-dd HH:mm:ss")
                } catch {
                    $modTime = [string]$f.modifiedTime
                }
            }

            [PSCustomObject]@{
                ID           = $f.id
                Name         = $f.name
                Size         = Format-FileSize ([long]$f.size)
                MimeType     = $f.mimeType
                ModifiedTime = $modTime
            }
        }

        Write-Host ""
        Write-Host ("Bucket Files (" + $files.Count + " total):") -ForegroundColor Cyan
        Write-Host ($tableItems | Format-Table -AutoSize | Out-String -Width 4096)
    } catch {
        Write-Host -ForegroundColor Red ("Error listing files: " + $_.Exception.Message)
        exit 1
    } finally {
        $client.Dispose()
    }
}

function Invoke-Download($cfg, $opts) {
    $apiKey = Ensure-ApiKey $cfg $opts
    $baseUrl = if ($opts.Url) { $opts.Url.TrimEnd('/') } else { $cfg.BaseUrl }

    $target = $opts.Target
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Host -ForegroundColor Red "Error: File ID or filename is required for download. Usage: bucket-script download <file-id-or-name> [--out <dest>]"
        exit 1
    }

    # Normalize backslashes to forward slashes for vanity names
    $normalizedTarget = $target.Replace("\", "/")
    $isLikelyFileName = $normalizedTarget.Contains(".") -or $normalizedTarget.Contains("/")

    $candidateUrls = [System.Collections.Generic.List[string]]::new()
    if ($isLikelyFileName) {
        # Prioritize /raw/{filename}, fallback to /files/{id}
        $escaped = [System.Uri]::EscapeDataString($normalizedTarget).Replace("%2F", "/")
        $candidateUrls.Add("$baseUrl/raw/$escaped")
        $candidateUrls.Add("$baseUrl/files/$target")
    } else {
        # Prioritize /files/{id}, fallback to /raw/{filename}
        $candidateUrls.Add("$baseUrl/files/$target")
        $escaped = [System.Uri]::EscapeDataString($normalizedTarget)
        $candidateUrls.Add("$baseUrl/raw/$escaped")
    }

    $client = Create-HttpClient $apiKey
    $successResponse = $null
    $usedUrl = ""

    try {
        foreach ($candUrl in $candidateUrls) {
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $candUrl)
            $res = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if ($res.IsSuccessStatusCode) {
                $successResponse = $res
                $usedUrl = $candUrl
                break
            }
            elseif ($res.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                $res.Dispose()
                continue
            }
            else {
                Handle-HttpError $res "download"
                $res.Dispose()
                exit 1
            }
        }

        if (-not $successResponse) {
            Write-Host -ForegroundColor Red ("Error: File '" + $target + "' not found on server.")
            exit 1
        }

        # Resolve destination filename
        $suggestedName = ""
        $disposition = $successResponse.Content.Headers.ContentDisposition
        if ($disposition -and $disposition.FileName) {
            $suggestedName = $disposition.FileName.Trim('"')
        }
        if ([string]::IsNullOrWhiteSpace($suggestedName)) {
            $suggestedName = [System.IO.Path]::GetFileName($normalizedTarget)
        }
        if ([string]::IsNullOrWhiteSpace($suggestedName)) {
            $suggestedName = "downloaded_file"
        }

        $destPath = ""
        $out = $opts.Out
        if ([string]::IsNullOrWhiteSpace($out)) {
            $destPath = Join-Path (Get-Location) $suggestedName
        } else {
            if ((Test-Path -LiteralPath $out -PathType Container) -or $out.EndsWith("/") -or $out.EndsWith("\")) {
                if (-not (Test-Path -LiteralPath $out)) {
                    [System.IO.Directory]::CreateDirectory($out) | Out-Null
                }
                $destPath = Join-Path $out $suggestedName
            } else {
                $destPath = $out
            }
        }

        $destPath = [System.IO.Path]::GetFullPath($destPath)
        $destDir = [System.IO.Path]::GetDirectoryName($destPath)
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
            [System.IO.Directory]::CreateDirectory($destDir) | Out-Null
        }

        Write-Host ("Downloading '" + $suggestedName + "' to '" + $destPath + "'...") -ForegroundColor Cyan

        $stream = $successResponse.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = [System.IO.File]::Create($destPath)
        $stream.CopyTo($fileStream)
        $fileStream.Dispose()
        $stream.Dispose()

        $downloadedSize = (Get-Item -LiteralPath $destPath).Length

        Write-Host ""
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host "  Download Successful" -ForegroundColor Green
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host ("  Source:   " + $target)
        Write-Host ("  Saved To: " + $destPath)
        Write-Host ("  Size:     " + (Format-FileSize $downloadedSize) + " (" + $downloadedSize + " bytes)")
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host ""
    } catch {
        Write-Host -ForegroundColor Red ("Error downloading file: " + $_.Exception.Message)
        exit 1
    } finally {
        if ($successResponse) { $successResponse.Dispose() }
        $client.Dispose()
    }
}

function Invoke-Delete($cfg, $opts) {
    $apiKey = Ensure-ApiKey $cfg $opts
    $baseUrl = if ($opts.Url) { $opts.Url.TrimEnd('/') } else { $cfg.BaseUrl }

    $target = $opts.Target
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Host -ForegroundColor Red "Error: File ID or filename is required for delete. Usage: bucket-script delete <file-id-or-name>"
        exit 1
    }

    $client = Create-HttpClient $apiKey
    $deleteId = ""
    $displayName = $target

    try {
        # First, query /files to resolve filename to ID if possible
        $listUrl = "$baseUrl/files"
        $listResp = $client.GetAsync($listUrl).GetAwaiter().GetResult()
        if ($listResp.IsSuccessStatusCode) {
            $jsonStr = $listResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $files = $jsonStr | ConvertFrom-Json
            if ($files) {
                # Look for exact name match (or match on base filename)
                $targetLeaf = [System.IO.Path]::GetFileName($target.Replace("\", "/"))
                $match = $files | Where-Object {
                    $_.name -ieq $target -or $_.name -ieq $targetLeaf
                } | Select-Object -First 1

                if (-not $match) {
                    # Look for ID match in the list
                    $match = $files | Where-Object { $_.id -ieq $target } | Select-Object -First 1
                }

                if ($match) {
                    $deleteId = $match.id
                    $displayName = $match.name
                }
            }
        }
        $listResp.Dispose()

        # If not found in /files, treat target directly as file ID
        if ([string]::IsNullOrWhiteSpace($deleteId)) {
            $deleteId = $target
        }

        Write-Host ("Deleting file '" + $displayName + "' (ID: " + $deleteId + ")...") -ForegroundColor Cyan

        $delUrl = "$baseUrl/files/$deleteId"
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Delete, $delUrl)
        $delResp = $client.SendAsync($req).GetAwaiter().GetResult()

        if ($delResp.IsSuccessStatusCode) {
            Write-Host ""
            Write-Host ("Successfully deleted '" + $displayName + "' (ID: " + $deleteId + ") from Google Drive bucket.") -ForegroundColor Green
            Write-Host ""
        } elseif ($delResp.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
            Write-Host ""
            Write-Host ("Error: File '" + $target + "' not found.") -ForegroundColor Red
            Write-Host ""
            exit 1
        } else {
            Handle-HttpError $delResp "delete"
            exit 1
        }
        $delResp.Dispose()
    } catch {
        Write-Host -ForegroundColor Red ("Error deleting file: " + $_.Exception.Message)
        exit 1
    } finally {
        $client.Dispose()
    }
}

# ------------------------------------------------------------------------------
# Entry Point
# ------------------------------------------------------------------------------

$options = Parse-CommandLineArgs $args
$config = Load-AppConfig

switch ($options.Command) {
    "health"      { Invoke-Health $config $options }
    "status"      { Invoke-Health $config $options }
    "config"      { Invoke-Config $config $options }
    "upload"      { Invoke-UploadFile $config $options }
    "upload-text" { Invoke-UploadText $config $options }
    "list"        { Invoke-List $config $options }
    "ls"          { Invoke-List $config $options }
    "download"    { Invoke-Download $config $options }
    "get"         { Invoke-Download $config $options }
    "pull"        { Invoke-Download $config $options }
    "delete"      { Invoke-Delete $config $options }
    "rm"          { Invoke-Delete $config $options }
    "del"         { Invoke-Delete $config $options }
    "help"        { Show-Help }
    default {
        Write-Host ""
        Write-Host ("Error: Unknown command or file not found: '" + $options.Target + "'") -ForegroundColor Red
        Write-Host "Run 'bucket-script help' to view available commands." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}
