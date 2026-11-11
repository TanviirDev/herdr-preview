# herdr-preview for Windows: show a Markdown or HTML file in the Herdr app.
#   herdr-preview <file>              show it in the Preview panel (layout "preview")
#   herdr-preview <file> right|down   open it as a split pane beside the focused pane instead
# The web view is macOS-only, so on Windows HTML shows as plain text and web pages can't be
# shown; the panel's Open button sends them to your browser. Installed by install.ps1, along
# with herdr-preview.cmd so it runs from any shell.
param(
  [Parameter(Position = 0)][string]$Target,
  [Parameter(Position = 1)][string]$Where = "panel"
)
$ErrorActionPreference = "Stop"

if (-not $Target -or $Target -in @("-h", "--help")) {
  [Console]::Error.WriteLine("usage: herdr-preview <file.md|file.html|url> [right|down]")
  exit 2
}
if ($Where -notin @("panel", "right", "down")) {
  [Console]::Error.WriteLine("herdr-preview: second argument must be right or down, not '$Where'")
  exit 2
}

if ($Target -match '^(https?|file)://') {
  $file = $Target
  $Where = "panel"
} else {
  if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
    [Console]::Error.WriteLine("herdr-preview: no such file: $Target")
    exit 1
  }
  $file = (Resolve-Path -LiteralPath $Target).ProviderPath
}

# Windows PowerShell and PowerShell before 7.3 drop the quotes inside a native command's
# argument, so a JSON argument needs them escaped there.
function Native-Json([string]$json) {
  if ($PSVersionTable.PSVersion -lt [version]"7.3") { return $json.Replace('"', '\"') }
  return $json
}

function Split-Pane([string]$direction) {
  $props = @{ file = $file } | ConvertTo-Json -Compress
  & herdr-app do pane.split --direction $direction --mod preview --props (Native-Json $props) | Out-Null
  exit $LASTEXITCODE
}

if ($Where -ne "panel") { Split-Pane $Where }

# The panel follows this file: line 1 is what to show, line 2 an optional label. Written
# whole, then moved into place, so the panel never reads half a path.
$state = Join-Path $HOME ".local\state\herdr-preview"
New-Item -ItemType Directory -Force -Path $state | Out-Null
$tmp = Join-Path $state "target.tmp"
[System.IO.File]::WriteAllText($tmp, "$file`n`n", [System.Text.UTF8Encoding]::new($false))
Move-Item -Force -LiteralPath $tmp -Destination (Join-Path $state "target")

& herdr-app do layout.show --id preview-panel 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Split-Pane "right" }
