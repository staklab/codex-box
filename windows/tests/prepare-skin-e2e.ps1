$ErrorActionPreference = 'Stop'
$fixture = Join-Path $env:RUNNER_TEMP 'codex-box-skin-e2e'
New-Item -ItemType Directory -Force $fixture | Out-Null
npm install --prefix $fixture --no-save electron@40.0.0
if ($LASTEXITCODE -ne 0) { throw 'Electron 下载失败' }
$dist = Join-Path $fixture 'node_modules/electron/dist'
Copy-Item (Join-Path $dist 'electron.exe') (Join-Path $dist 'Codex.exe')
Copy-Item 'tests/electron' (Join-Path $dist 'resources/app') -Recurse
$cli = Join-Path $fixture 'cli'
New-Item -ItemType Directory -Force $cli | Out-Null
rustc tests/skin-cli-sentinel.rs -o (Join-Path $cli 'codex.exe')
if ($LASTEXITCODE -ne 0) { throw 'CLI 测试进程编译失败' }
"CODEX_BOX_E2E_DESKTOP=$(Join-Path $dist 'Codex.exe')" >> $env:GITHUB_ENV
"CODEX_BOX_E2E_CLI=$(Join-Path $cli 'codex.exe')" >> $env:GITHUB_ENV
"CODEX_BOX_E2E_ARTIFACTS=$env:RUNNER_TEMP/codex-box-skin-results" >> $env:GITHUB_ENV
