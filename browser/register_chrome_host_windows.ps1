$ErrorActionPreference = 'Stop'
$hostPath = Join-Path $PSScriptRoot 'idm_native_host.exe'
$setupScript = Join-Path $PSScriptRoot 'setup_chrome_host_windows.ps1'

if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
  throw "IDM native host executable was not found: $hostPath"
}

$extensionId = Read-Host 'Paste the IDM Chrome extension ID from chrome://extensions'
try {
  & $setupScript -HostPath $hostPath -ExtensionId $extensionId
} catch {
  Write-Host "Native host registration failed: $_" -ForegroundColor Red
  Read-Host 'Press Return to close'
  exit 1
}
Read-Host 'Chrome native host registered. Restart Chrome, then press Return to close'
