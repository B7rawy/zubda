<#
  Zubda for Windows: one-command install. Safe to run again to update.
    1. Python environment with faster-whisper in %USERPROFILE%\.local\share\meeting-recorder\venv
    2. Voice-separation models (about 45 MB)
    3. Settings file %APPDATA%\meeting-recorder\config.json (kept if it exists)
    4. Connects Claude Desktop and Claude Code, installs the "meeting" skill
    5. Start menu shortcut, then opens Zubda
  Run from the repo folder:   powershell -ExecutionPolicy Bypass -File .\setup.ps1
  Add -DownloadModel to fetch the Whisper model now (about 1.6 GB) instead of on the first meeting.
#>
param([switch]$DownloadModel, [switch]$NoLaunch)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$Data = Join-Path $env:USERPROFILE ".local\share\meeting-recorder"
$Venv = Join-Path $Data "venv"
$Py = Join-Path $Venv "Scripts\python.exe"
$PyW = Join-Path $Venv "Scripts\pythonw.exe"
$ConfigDir = Join-Path $env:APPDATA "meeting-recorder"

function Step($text) { Write-Host "`n==> $text" -ForegroundColor DarkYellow }

if (-not [Environment]::Is64BitOperatingSystem) { throw "Zubda needs 64-bit Windows 10 or 11." }

Step "Python"
$Base = $null
foreach ($v in "3.12", "3.11", "3.13") {
  try { $found = & py "-$v" -c "import sys; print(sys.executable)" 2>$null; if ($LASTEXITCODE -eq 0 -and $found) { $Base = $found.Trim(); break } } catch {}
}
if (-not $Base) {
  try { $found = & python -c "import sys; assert (3,10) <= sys.version_info[:2] <= (3,13); print(sys.executable)" 2>$null; if ($LASTEXITCODE -eq 0) { $Base = $found.Trim() } } catch {}
}
if (-not $Base) {
  throw "Python 3.11 or 3.12 is needed. Install it with:  winget install -e --id Python.Python.3.12   then run this again."
}
Write-Host "Using $Base"

Step "Python environment (first run downloads about 600 MB of libraries)"
New-Item -ItemType Directory -Force -Path $Data | Out-Null
if (-not (Test-Path $Py)) { & $Base -m venv $Venv }
& $Py -m pip install --quiet --upgrade pip
& $Py -m pip install --quiet -r (Join-Path $Repo "windows\requirements.txt")
if ($LASTEXITCODE -ne 0) { throw "Installing the Python libraries failed." }

Step "Voice separation models (about 45 MB, runs on this computer)"
$Models = Join-Path $Data "models"
New-Item -ItemType Directory -Force -Path $Models | Out-Null
$Releases = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
if (-not (Test-Path (Join-Path $Models "sherpa-onnx-pyannote-segmentation-3-0\model.onnx"))) {
  $archive = Join-Path $env:TEMP "zubda-segmentation.tar.bz2"
  Invoke-WebRequest -UseBasicParsing "$Releases/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2" -OutFile $archive
  tar -xjf $archive -C $Models
  Remove-Item $archive
}
if (-not (Test-Path (Join-Path $Models "embedding.onnx"))) {
  Invoke-WebRequest -UseBasicParsing "$Releases/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx" -OutFile (Join-Path $Models "embedding.onnx")
}

Step "Settings"
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$Config = Join-Path $ConfigDir "config.json"
if (-not (Test-Path $Config)) {
  Copy-Item (Join-Path $Repo "config.example.json") $Config
  Write-Host "Created $Config; set your name and languages in Zubda > Settings."
} else { Write-Host "Keeping $Config" }

Step "Connect Claude to your meetings"
& $Py (Join-Path $Repo "connect_claude.py")

Step "Claude Code skill"
$Skill = Join-Path $env:USERPROFILE ".claude\skills\meeting"
New-Item -ItemType Directory -Force -Path $Skill | Out-Null
(Get-Content (Join-Path $Repo "skill\SKILL.md") -Raw -Encoding UTF8).Replace("{{REPO}}", $Repo).Replace("{{PYTHON}}", $Py) |
  Set-Content (Join-Path $Skill "SKILL.md") -Encoding UTF8

Step "Start menu shortcut"
$Icon = Join-Path $Repo "windows\zubda\assets\icon.ico"
& $Py -c "from PySide6.QtGui import QImage; QImage(r'$Repo\windows\zubda\assets\icon.png').save(r'$Icon')"
$Shell = New-Object -ComObject WScript.Shell
$Link = $Shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Programs")) "Zubda.lnk"))
$Link.TargetPath = $PyW
$Link.Arguments = "`"$Repo\windows\Zubda.pyw`""
$Link.WorkingDirectory = $Repo
if (Test-Path $Icon) { $Link.IconLocation = $Icon }
$Link.Description = "Zubda: record, transcribe and summarise meetings"
$Link.Save()
Write-Host "Zubda is in the Start menu."

if ($DownloadModel) {
  Step "Whisper model (one time, about 1.6 GB)"
  & $Py -c "import sys; sys.path.insert(0, r'$Repo'); import whisper_engine, numpy; whisper_engine.transcribe(numpy.zeros(16000, dtype='float32'), 'large-v3-turbo'); print('Model ready')"
}

Step "Checks"
& $Py -c "import sys; sys.path.insert(0, r'$Repo'); import faster_whisper, imageio_ffmpeg, pyaudiowpatch, PySide6, whisper_engine; print('Whisper, audio and window libraries: OK')"
& $Py -c "import sys; sys.path.insert(0, r'$Repo'); import diarize; print('Voice separation: OK' if diarize.available() else 'Voice separation: missing')"
$Claude = & $Py -c "import sys; sys.path.insert(0, r'$Repo'); import config; print(config.claude_path() or '')"
if ($Claude) { Write-Host "claude CLI found: reports work once it's logged in (run: claude, then /login)." }
else { Write-Host "claude CLI not found: recordings and transcripts work; reports need Claude Code (https://claude.com/claude-code)." }

if (-not $NoLaunch) {
  Start-Process $PyW -ArgumentList "`"$Repo\windows\Zubda.pyw`"" -WorkingDirectory $Repo
  Write-Host "`nDone. Zubda is open: move the pointer to the black bar at the top of the screen."
}
