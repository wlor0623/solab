$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-Contains([string]$path, [string]$pattern) {
    $content = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $path)
    if ($content -notmatch $pattern) {
        throw "SoLab identity check failed: $path does not match $pattern"
    }
}

Assert-Contains 'pubspec.yaml' '(?m)^name:\s*solab\s*$'
Assert-Contains 'android/app/build.gradle.kts' 'namespace\s*=\s*"zhou\.solab"'
Assert-Contains 'android/app/build.gradle.kts' 'applicationId\s*=\s*"zhou\.solab"'
Assert-Contains 'android/app/src/main/AndroidManifest.xml' 'android:label="SoLab"'
Assert-Contains 'android/app/src/main/AndroidManifest.xml' 'android:scheme="zhou\.solab"'
Assert-Contains 'lib/core/services/local_tools/local_tool_names.dart' "get_solab_tool_map"
Assert-Contains 'lib/features/solab_apk/services/apk_toolchain_service.dart' "solab/workspace"

$legacyImports = & rg -n 'package:Kelivo/' (Join-Path $repoRoot 'lib') 2>$null
if ($LASTEXITCODE -eq 0 -and $legacyImports) {
    throw "Legacy Dart package imports returned:`n$legacyImports"
}

Write-Output 'SoLab project identity is consistent.'
