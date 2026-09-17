param(
    [string]$Branch = 'master',
    [string]$RemoteUrl = 'https://github.com/Chevey339/kelivo.git'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot

if (git status --porcelain) {
    throw 'Commit or stash local changes before syncing upstream.'
}

if (-not (git remote | Select-String -SimpleMatch 'upstream')) {
    git remote add upstream $RemoteUrl
}

git fetch upstream $Branch
if ($LASTEXITCODE -ne 0) { throw 'Failed to fetch upstream.' }
$preflight = git merge-tree --write-tree HEAD "upstream/$Branch" 2>&1
if ($LASTEXITCODE -ne 0) {
    $conflictCount = @($preflight | Select-String '^CONFLICT').Count
    throw "Upstream merge preflight found $conflictCount conflicts; the working tree was not changed."
}
git merge --no-edit "upstream/$Branch"
if ($LASTEXITCODE -ne 0) { throw 'Upstream merge needs manual conflict resolution.' }

& (Join-Path $PSScriptRoot 'check_project_identity.ps1')
flutter pub get
flutter analyze
flutter test test/features/home/services/tool_registry_consistency_test.dart test/core/services/mcp_server/mcp_http_server_test.dart

Write-Output 'Upstream merged and SoLab checks passed.'
