[CmdletBinding()]
param(
    [string]$JdkPath = $env:JAVA_HOME
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDirectory
$delivery = $null
$buildLock = [System.Threading.Mutex]::new($false, 'SoLabAndroidArm64Build')
$lockHeld = $false

$javaExecutable = if ($JdkPath) { Join-Path $JdkPath 'bin\java.exe' } else { 'java' }
if ($JdkPath -and -not (Test-Path -LiteralPath $javaExecutable -PathType Leaf)) {
    throw "JDK was not found at: $JdkPath"
}
$javaVersion = (& $javaExecutable --version | Select-Object -First 1).ToString()
if ($javaVersion -notmatch '^(?:openjdk|java) 21[\.]') {
    throw "Android release builds require JDK 21. Current runtime: $javaVersion"
}

try {
    $lockHeld = $buildLock.WaitOne(0)
    if (-not $lockHeld) {
        throw 'Another Android release build is already running.'
    }

    Push-Location $projectRoot
    try {
        & flutter build apk --release --target-platform android-arm64
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter release build failed with exit code $LASTEXITCODE."
        }

        $sourceApk = Join-Path $projectRoot 'build/app/outputs/flutter-apk/app-release.apk'
        if (-not (Test-Path -LiteralPath $sourceApk -PathType Leaf)) {
            throw "Release APK was not created: $sourceApk"
        }

        $versionLine = Select-String -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Pattern '^version:\s*([^+\s]+)' | Select-Object -First 1
        $version = if ($versionLine) { $versionLine.Matches[0].Groups[1].Value } else { 'unknown' }
        $distDirectory = Join-Path $projectRoot 'dist'
        $outputApk = Join-Path $distDirectory "SoLab-$version-arm64-v8a.apk"
        New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null
        Copy-Item -LiteralPath $sourceApk -Destination $outputApk -Force
        $delivery = [pscustomobject]@{
            Path = $outputApk
            Bytes = (Get-Item -LiteralPath $outputApk).Length
            Sha256 = (Get-FileHash -LiteralPath $outputApk -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($lockHeld) { $buildLock.ReleaseMutex() }
    $buildLock.Dispose()
}

$delivery
