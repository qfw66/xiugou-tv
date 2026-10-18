<#
.SYNOPSIS
    XiugouTV - Minimal Embedded JRE Generator via jlink
.DESCRIPTION
    Creates a lightweight, portable JRE runtime (approx. 30-40MB) tailored for
    the XiugouTV Companion Service, so end-users do not need to install Java.
.PARAMETER OutputDir
    Destination folder for the minimal JRE (Default: xiugou-tv/runtime/jre).
#>

param (
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path "$ScriptDir/..").Path

if ($OutputDir -eq "") {
    $OutputDir = Join-Path $ProjectRoot "runtime/jre"
}

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  XiugouTV - Minimal JRE Generator" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# 1. Locate jlink in JDK
$JLink = $null
$SysJlink = Get-Command "jlink" -ErrorAction SilentlyContinue
if ($SysJlink) {
    $JLink = $SysJlink.Source
} elseif ($env:JAVA_HOME) {
    $Candidate = Join-Path $env:JAVA_HOME "bin/jlink.exe"
    if (Test-Path $Candidate) {
        $JLink = $Candidate
    }
}

if (-not $JLink) {
    # Check registry for JDK
    $RegJdk = Get-ItemProperty 'HKLM:\SOFTWARE\JavaSoft\JDK\*', 'HKLM:\SOFTWARE\JavaSoft\Java Development Kit\*' -ErrorAction SilentlyContinue
    if ($RegJdk -and $RegJdk.JavaHome) {
        $Candidate = Join-Path $RegJdk.JavaHome "bin/jlink.exe"
        if (Test-Path $Candidate) {
            $JLink = $Candidate
        }
    }
}

if (-not $JLink) {
    $CommonCandidates = @(
        "D:\dev\1ajavase\jdk21\bin\jlink.exe",
        "C:\Program Files\Java\jdk-21\bin\jlink.exe",
        "C:\Program Files\Java\jdk-17\bin\jlink.exe",
        "C:\Program Files\Eclipse Adoptium\jdk-21*\bin\jlink.exe"
    )
    foreach ($cand in $CommonCandidates) {
        if (Test-Path $cand) {
            $JLink = (Resolve-Path $cand).Path
            break
        }
    }
}

if (-not $JLink) {
    Write-Error "jlink command not found. Please ensure a JDK 17+ or JDK 21 is installed and in PATH or JAVA_HOME."
}

Write-Host "[+] Found jlink at: $JLink" -ForegroundColor Green

# 2. Required modules for Spider & Companion Service
# NOTE: jdk.crypto.ec must be explicit. It provides ECDHE key exchange; without it
# HTTPS handshakes to most sites fail (upstream returns empty -> spider parse errors),
# and the failure never reproduces on a dev machine that runs a full system JDK.
# jdk.charsets is needed to decode GBK pages, common on video sites.
# java.management is required by unidbg (android-bridge guard decrypt subprocess):
#   AbstractEmulator <clinit> touches java.lang.management.ManagementFactory.
# jdk.zipfs is required by dex2jar (DexFileFactory writes through a zip filesystem):
#   without it the converter throws "cant find zipfs support" and the payload
#   silently falls back to the raw shell jar, i.e. every Guard site goes blank.
$Modules = @(
    "java.base",
    "java.desktop",
    "java.logging",
    "java.management",
    "java.naming",
    "java.net.http",
    "java.sql",
    "java.xml",
    "jdk.crypto.ec",
    "jdk.charsets",
    "jdk.httpserver",
    "jdk.unsupported",
    "jdk.zipfs"
) -join ","

# 3. Clean target directory
if (Test-Path $OutputDir) {
    Write-Host "[*] Removing existing runtime at $OutputDir..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force $OutputDir
}

$ParentDir = Split-Path -Parent $OutputDir
if (!(Test-Path $ParentDir)) {
    New-Item -ItemType Directory -Force -Path $ParentDir | Out-Null
}

Write-Host "[*] Generating minimal JRE with modules: $Modules..." -ForegroundColor Cyan

& $JLink `
    --no-header-files `
    --no-man-pages `
    --compress=2 `
    --strip-debug `
    --add-modules $Modules `
    --output $OutputDir

$JavaExe = Join-Path $OutputDir "bin/java.exe"
if (Test-Path $JavaExe) {
    $SizeMB = [math]::Round(((Get-ChildItem -Path $OutputDir -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB), 2)
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host "  Minimal JRE successfully created at: $OutputDir" -ForegroundColor Green
    Write-Host "  Total Runtime Size: $SizeMB MB" -ForegroundColor Green
    Write-Host "  Executable: $JavaExe" -ForegroundColor Green
    Write-Host "======================================================" -ForegroundColor Green
} else {
    Write-Error "Failed to generate JRE at $OutputDir"
}
