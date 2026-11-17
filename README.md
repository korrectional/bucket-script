# bucket-script

Production-grade Windows PowerShell CLI tool and wrapper for **Bucketloader** — a headless Google Drive storage backend and file serving service hosted at `https://kanevskyy.dev/bucket`.

Compatible with both **Windows PowerShell 5.1** (pre-installed on Windows 10/11) and **PowerShell 7+** (Core), as well as Windows Command Prompt (`cmd.exe`) and Windows Terminal.

---

## Features

- **Zero-Dependency Multipart HTTP**: Built on .NET's `System.Net.Http.HttpClient` and `MultipartFormDataContent` — no PowerShell 5.1 `-Form` parameter incompatibilities, memory leaks, or file-encoding corruptions.
- **Shorthand Invocations**: Simply run `bucket-script <path-to-file>` anywhere to instantly upload.
- **Dual CMD / Batch Wrappers**: Run `bucket-script` directly from Command Prompt or PowerShell anywhere on Windows without typing `.ps1` or dealing with execution policy flags.
- **Automatic Name-to-ID Resolution**: Delete or download files by their vanity filename or their Google Drive file ID.
- **Resilient Config Hierarchy**: Reads `BUCKET_API_KEY` and `BUCKET_BASE_URL` from environment variables, falling back to `$env:USERPROFILE\.bucket-script\config.json`.
- **Automated Installer**: Single-command setup that provisions user binaries, sets user `PATH`, and sets up local configuration.

---

## Installation (Windows)

Clone or download this repository, open PowerShell or Command Prompt, and run the automated installer:

```powershell
powershell -ExecutionPolicy Bypass -File .\installation.ps1
```

Or pass your API key directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\installation.ps1 -ApiKey "YOUR_API_KEY"
```

### What `installation.ps1` does:
1. Creates `$env:USERPROFILE\.bucket-script\bin` and installs `bucket-script.ps1`, `bucket-script.cmd`, and `bucket-script.bat`.
2. Permanently adds `$env:USERPROFILE\.bucket-script\bin` to your **Windows User `PATH`** environment variable (`[Environment]::SetEnvironmentVariable("Path", ..., "User")`).
3. Updates the current session `$env:PATH`.
4. Saves your API credentials to `$env:USERPROFILE\.bucket-script\config.json`.

After installation, open any new Command Prompt, PowerShell, or Windows Terminal window and run:

```cmd
bucket-script health
```

---

## Configuration & Credentials

`bucket-script` looks for credentials in the following order:

1. **Environment Variables**:
   - `BUCKET_API_KEY`: API key passed in `X-API-Key` HTTP header.
   - `BUCKET_BASE_URL`: Base service URL (defaults to `https://kanevskyy.dev/bucket`).
2. **Config File**:
   - Location: `$env:USERPROFILE\.bucket-script\config.json`
   - Format:
     ```json
     {
       "api_key": "YOUR_API_KEY",
       "base_url": "https://kanevskyy.dev/bucket"
     }
     ```

### Managing Configuration via CLI

To update or set your API key at any time:

```cmd
bucket-script config --api-key <YOUR_API_KEY>
```

To specify a custom base URL (e.g. for local testing or custom proxy):

```cmd
bucket-script config --api-key <YOUR_API_KEY> --url http://127.0.0.1:8090
```

---

## Command Reference

### 1. Health & Status
Verify connectivity, Google Drive OAuth status, and the configured bucket folder ID:

```cmd
bucket-script health
```
*(Alias: `bucket-script status`)*

```text
====================================================
  Bucketloader Service Health
====================================================
  Endpoint:            https://kanevskyy.dev/bucket/health
  Status:              ok
  Drive Authenticated: True
  Credentials Config:  True
  Bucket Folder ID:    1BSAxYwSDzswGNLxWy69m1aoYjDvVII0w
====================================================
```

---

### 2. File Uploads

#### Shorthand Upload
If the first positional argument is an existing local file, `bucket-script` automatically uploads it:

```cmd
bucket-script ./render.png
bucket-script ./report.pdf --overwrite
bucket-script ./release.zip --name "latest-release.zip"
```

#### Standard Upload
```cmd
bucket-script upload <path-to-file> [--name <custom-name>] [--overwrite] [--subfolder <folder>]
```

**Options:**
- `--name, -n <filename>`: Custom filename to assign in the bucket.
- `--overwrite, -f`: Overwrites any existing file with the same name.
- `--subfolder <folder>`: Uploads into a specific subfolder (e.g., `renders` or `backups/2026`).

**Example:**
```cmd
bucket-script upload ./dist/bundle.zip --name "release-v1.0.0.zip" --overwrite
```

**Output:**
```text
Uploading 'bundle.zip' (2.45 MB) as 'release-v1.0.0.zip'...

====================================================
  Upload Successful
====================================================
  File ID:     1BSAxYwSDzswGNLxWy69m1aoYjDvVII0w
  Name:        release-v1.0.0.zip
  Size:        2.45 MB (2569012 bytes)
  MIME Type:   application/zip
  Direct URL:  https://kanevskyy.dev/bucket/files/1BSAxYwSDzswGNLxWy69m1aoYjDvVII0w
  Raw URL:     https://kanevskyy.dev/bucket/raw/release-v1.0.0.zip
====================================================
```

---

### 3. Upload Text Directly
Upload raw string content or log output directly as a file without writing a temporary local file:

```cmd
bucket-script upload-text "<text-content>" --name <filename> [--overwrite] [--subfolder <folder>]
```

**Example:**
```cmd
bucket-script upload-text "Build 142 completed at 2026-11-17" --name "logs/build.log"
```

---

### 4. List Files
List all files stored in the bucket folder:

```cmd
bucket-script list
```
*(Alias: `bucket-script ls`)*

To list files inside a specific subfolder:
```cmd
bucket-script list --subfolder "renders"
```

**Output:**
```text
Bucket Files (2 total):

ID                                Name                Size    MimeType            ModifiedTime
--                                ----                ----    --------            ------------
1BSAxYwSDzswGNLxWy69m1aoYjDvVII0w release-v1.0.0.zip 2.45 MB application/zip     2026-11-17 03:23:48
1XGer5umCUPOvjSLmdrLd23WTHt3OSpg2 notes.txt           33 B    text/plain          2026-11-17 03:41:42
```

---

### 5. Download Files
Download files by vanity filename (`GET /raw/{filename}`) or by Google Drive file ID (`GET /files/{id}`):

```cmd
bucket-script download <file-id-or-name> [--out <destination-path>]
```
*(Aliases: `bucket-script get`, `bucket-script pull`)*

- If `--out` is omitted, saves to the current working directory with the remote filename.
- If `--out` points to a directory (e.g. `C:\Downloads\` or `./out/`), saves inside that folder.
- If `--out` points to a filename, saves directly to that path.

**Examples:**
```cmd
# Download by vanity filename
bucket-script download release-v1.0.0.zip

# Download by Google Drive file ID
bucket-script download 1BSAxYwSDzswGNLxWy69m1aoYjDvVII0w --out C:\Backups\archive.zip

# Download to a specific folder
bucket-script download notes.txt --out ./downloads/
```

---

### 6. Delete Files
Delete a file by its vanity filename or Google Drive file ID:

```cmd
bucket-script delete <file-id-or-name>
```
*(Aliases: `bucket-script rm`, `bucket-script del`)*

When given a filename, `bucket-script` automatically resolves the filename to its corresponding file ID via `GET /files` and calls `DELETE /files/{id}`.

**Examples:**
```cmd
bucket-script delete release-v1.0.0.zip
bucket-script rm 1BSAxYwSDzswGNLxWy69m1aoYjDvVII0w
```

---

### 7. Help
Display the CLI manual and usage examples:

```cmd
bucket-script help
```

---

## Project Structure

```text
bucket-script/
├── bucket-script.ps1     # Core CLI implementation (PowerShell 5.1 & 7+ compatible)
├── bucket-script.cmd     # Windows Command Prompt / CMD execution wrapper
├── bucket-script.bat     # Windows Batch execution wrapper
├── installation.ps1      # Automated installer for Windows environments
├── .gitignore            # Git exclusion rules (ignores secrets & local configs)
└── README.md             # Documentation and usage guide
```

---

## Technical Details

- **MIME Detection**: Built-in resolution for common file formats (images, documents, archives, audio, video, code) falling back to `application/octet-stream`.
- **TLS 1.2 Enforcement**: Explicitly enables `SecurityProtocolType.Tls12` on older Windows PowerShell 5.1 environments to ensure secure HTTPS connections.
- **Large File Streaming**: Uploads stream from disk via `System.IO.File::OpenRead` and `StreamContent` rather than loading entire files into memory. Downloads stream directly via `CopyTo` on the response stream.
- **Cross-Shell Launcher**: `bucket-script.cmd` checks for `pwsh.exe` in `PATH` to utilize modern PowerShell 7+ if installed, gracefully falling back to `powershell.exe` with `-ExecutionPolicy Bypass -NoProfile`.
