# Removes herdr-preview on Windows: switches the Herdr window back to the main layout and
# deletes only what install.ps1 added. Uses the same HERDR_APP_HOME and HERDR_PREVIEW_BIN_DIR.
#   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
$ErrorActionPreference = "Stop"

$appHome = if ($env:HERDR_APP_HOME) { $env:HERDR_APP_HOME } else { Join-Path $HOME ".config\herdr-app" }
$binDir = if ($env:HERDR_PREVIEW_BIN_DIR) { $env:HERDR_PREVIEW_BIN_DIR } else { Join-Path $HOME ".local\bin" }

function Test-Ours([string]$path) {
  $files = Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue
  if (-not $files) { return $false }
  return [bool](Select-String -LiteralPath $files.FullName -Pattern 'herdr-preview|preview-tabs' -Quiet)
}

function Remove-Ours([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  if (Test-Ours $path) { Remove-Item -Recurse -Force -LiteralPath $path; Write-Output "removed: $path" }
  else { Write-Output "kept (not from herdr-preview): $path" }
}

# 1. Leave the preview layout if it's showing, before its files go.
if (Get-Command herdr-app -ErrorAction SilentlyContinue) {
  $status = (& herdr-app status 2>$null) -join "`n"
  if ($status -match '"layout":\s*"preview"') {
    & herdr-app do layout.switch --name main 2>$null | Out-Null
    Write-Output "switched the Herdr window back to the main layout"
  }
}

# 2. The layout, mods and command.
Remove-Ours (Join-Path $appHome "layouts\preview.json")
Remove-Ours (Join-Path $appHome "mods\preview")
Remove-Ours (Join-Path $appHome "mods\preview-tabs")
Remove-Ours (Join-Path $binDir "herdr-preview.ps1")
Remove-Ours (Join-Path $binDir "herdr-preview.cmd")

# 3. Its own state files only; the folders go if nothing else is in them.
foreach ($f in @("herdr-preview\panel.json", "herdr-preview\reload")) {
  Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath (Join-Path $appHome $f)
}
$state = Join-Path $HOME ".local\state\herdr-preview"
Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath (Join-Path $state "target"), (Join-Path $state "target.tmp")
foreach ($dir in @((Join-Path $appHome "herdr-preview"), $state)) {
  if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Item -LiteralPath $dir }
}

Write-Output "Done."
