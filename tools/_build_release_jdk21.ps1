# 本机正式包构建入口：强制 JDK 21（Gradle 8.14 与更高 JDK 不兼容）
$env:JAVA_HOME = 'D:\Environment\jdk21\jdk-21.0.6+7'
$env:PATH = $env:JAVA_HOME + '\bin;' + $env:PATH
java -version
& (Join-Path $PSScriptRoot 'build_android_arm64.ps1')
