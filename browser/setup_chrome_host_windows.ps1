param(
  [Parameter(Mandatory = $true)][string]$HostPath,
  [Parameter(Mandatory = $true)][string]$ExtensionId
)

$ErrorActionPreference = 'Stop'
$manifestName = 'com.tivoyudhap.internet_download_manager'
if ($ExtensionId -notmatch '^[a-p]{32}$') {
  throw 'Extension ID must be 32 characters containing only letters a-p.'
}
if (-not (Test-Path -LiteralPath $HostPath -PathType Leaf)) {
  throw "Native host executable was not found: $HostPath"
}

$absoluteHostPath = (Resolve-Path -LiteralPath $HostPath).Path
$manifestDirectory = Join-Path $env:LOCALAPPDATA 'InternetDownloadManager\NativeMessagingHosts'
New-Item -ItemType Directory -Force -Path $manifestDirectory | Out-Null
$manifestPath = Join-Path $manifestDirectory "$manifestName.json"
$manifest = @{
  name = $manifestName
  description = 'Internet Download Manager browser bridge'
  path = $absoluteHostPath
  type = 'stdio'
  allowed_origins = @("chrome-extension://$ExtensionId/")
} | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText(
  $manifestPath,
  $manifest,
  [System.Text.UTF8Encoding]::new($false)
)

$registryPath = "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$manifestName"
New-Item -Force -Path $registryPath | Out-Null
Set-Item -Path $registryPath -Value $manifestPath

Write-Output 'Native host registered for Google Chrome.'
