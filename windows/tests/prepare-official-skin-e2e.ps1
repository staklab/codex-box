$ErrorActionPreference = 'Stop'
$version = '26.825.6671.0'
$root = Join-Path $env:RUNNER_TEMP 'codex-official-skin-e2e'
New-Item -ItemType Directory -Force $root | Out-Null
$package = Join-Path $root 'ChatGPT-x64.msix'
Invoke-WebRequest "https://persistent.oaistatic.com/codex-app-prod/releases/$version/ChatGPT-x64.msix" -OutFile $package
$signature = Get-AuthenticodeSignature $package
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'OpenAI') { throw "官方 MSIX 签名验证失败：$($signature.Status)" }
Add-AppxPackage -Path $package
$installed = Get-AppxPackage OpenAI.Codex | Where-Object { $_.Version -eq $version } | Select-Object -First 1
if (-not $installed) { throw '官方 Codex MSIX 安装未完成' }
$desktop = Get-ChildItem $installed.InstallLocation -Filter ChatGPT.exe -Recurse | Where-Object { Test-Path (Join-Path $_.DirectoryName 'resources/app.asar') } | Select-Object -First 1
if (-not $desktop) { throw '官方 Codex Electron 桌面路径未找到' }
"CODEX_BOX_E2E_OFFICIAL=$($desktop.FullName)" >> $env:GITHUB_ENV
"CODEX_BOX_E2E_OFFICIAL_VERSION=$version" >> $env:GITHUB_ENV
