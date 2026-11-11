# Installs herdr-preview on Windows: the Preview panel, its layout and the herdr-preview command.
# The web view and .md click routing are macOS-only, so on Windows HTML shows as plain text.
#
# Usage (from this folder):
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 [-Update] [-NoSwitch]
#     -Update    replace the files from an earlier herdr-preview install (never anyone else's)
#     -NoSwitch  don't switch the Herdr window to the "preview" layout afterwards
#
# Where things go (override with these environment variables):
#   HERDR_APP_HOME          ~\.config\herdr-app  layouts\preview.json, mods\preview, mods\preview-tabs
#   HERDR_PREVIEW_BIN_DIR   ~\.local\bin         herdr-preview.cmd and herdr-preview.ps1
# Undo it with uninstall.ps1.
param([switch]$Update, [switch]$NoSwitch)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot

$appHome = if ($env:HERDR_APP_HOME) { $env:HERDR_APP_HOME } else { Join-Path $HOME ".config\herdr-app" }
$binDir = if ($env:HERDR_PREVIEW_BIN_DIR) { $env:HERDR_PREVIEW_BIN_DIR } else { Join-Path $HOME ".local\bin" }

# Every file herdr-preview installs names itself (the layout names its tab bar, preview-tabs).
function Test-Ours([string]$path) {
  $files = Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue
  if (-not $files) { return $false }
  return [bool](Select-String -LiteralPath $files.FullName -Pattern 'herdr-preview|preview-tabs' -Quiet)
}

# Copy, never over someone else's file; with -Update, replace our own.
function Place([string]$src, [string]$dst) {
  if (Test-Path -LiteralPath $dst) {
    if (-not (Test-Ours $dst)) { throw "$dst exists and isn't from herdr-preview; move it aside first" }
    if (-not $Update) { throw "$dst is from an earlier herdr-preview install; rerun with -Update to replace it" }
    Remove-Item -Recurse -Force -LiteralPath $dst
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
  Copy-Item -Recurse -LiteralPath $src -Destination $dst
  Write-Output "installed: $dst"
}

# 1. The Herdr layout and its two mods.
Place (Join-Path $here "preview\layouts\preview.json") (Join-Path $appHome "layouts\preview.json")
Place (Join-Path $here "preview\mods\preview") (Join-Path $appHome "mods\preview")
Place (Join-Path $here "preview\mods\preview-tabs") (Join-Path $appHome "mods\preview-tabs")

# 2. The command.
Place (Join-Path $here "bin\herdr-preview.ps1") (Join-Path $binDir "herdr-preview.ps1")
Place (Join-Path $here "bin\herdr-preview.cmd") (Join-Path $binDir "herdr-preview.cmd")
$onPath = ($env:PATH -split ';') | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') }
if (-not $onPath) {
  Write-Output "note: $binDir isn't on your PATH; add it to use herdr-preview from a terminal"
}

# 3. Check the mods load, then show the layout.
if (Get-Command herdr-app -ErrorAction SilentlyContinue) {
  & herdr-app check (Join-Path $appHome "mods\preview")
  & herdr-app check (Join-Path $appHome "mods\preview-tabs")
  if (-not $NoSwitch) {
    & herdr-app do layout.switch --name preview 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Output "switched the Herdr window to the preview layout (Ctrl+Shift+L cycles layouts)" }
    else { Write-Output "note: open the Herdr app, then pick the preview layout (Ctrl+Shift+L cycles layouts)" }
  }
} else {
  Write-Output "note: herdr-app isn't on PATH, so nothing was checked or switched in the Herdr app"
}

Write-Output ""
Write-Output "Done. Click Preview at the top right of the Herdr window, or run: herdr-preview README.md"
Write-Output "The web view and .md click routing are macOS-only; on Windows HTML shows as plain text."
