[CmdletBinding()]
param(
    [string]$SteamPath,
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\data\steam_apps.csv"),
    [switch]$AllAppTypes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-ProjectPath {
    param([string]$Path)

    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-SteamPath {
    param([string]$ExplicitPath)

    if ($ExplicitPath -and (Test-Path -LiteralPath $ExplicitPath)) {
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    $candidates = @(
        "C:\Program Files (x86)\Steam",
        "C:\Program Files\Steam"
    )

    $registryCandidates = @(
        @{ Path = "HKCU:\Software\Valve\Steam"; Name = "SteamPath" },
        @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam"; Name = "InstallPath" },
        @{ Path = "HKLM:\SOFTWARE\Valve\Steam"; Name = "InstallPath" }
    )

    foreach ($candidate in $registryCandidates) {
        $value = Get-ItemProperty -Path $candidate.Path -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty $candidate.Name -ErrorAction SilentlyContinue
        if ($value -and (Test-Path -LiteralPath $value)) {
            $candidates = @($value) + $candidates
        }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Could not find a Steam install. Pass -SteamPath explicitly."
}

$steamRoot = Get-SteamPath -ExplicitPath $SteamPath
$appInfoPath = Join-Path $steamRoot "appcache\appinfo.vdf"
if (-not (Test-Path -LiteralPath $appInfoPath)) {
    throw "Could not find appinfo.vdf at $appInfoPath."
}

$outputFile = Resolve-ProjectPath $OutputPath
$outputDirectory = Split-Path -Parent $outputFile
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$projectPath = Resolve-ProjectPath (Join-Path $PSScriptRoot "..\tools\SteamMetadataReader\SteamMetadataReader.csproj")
$repoRoot = Resolve-ProjectPath (Join-Path $PSScriptRoot "..")

$env:DOTNET_CLI_HOME = $repoRoot
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"
$env:NUGET_PACKAGES = Join-Path $repoRoot ".nuget\packages"
$env:APPDATA = Join-Path $repoRoot ".appdata"
New-Item -ItemType Directory -Force -Path $env:APPDATA | Out-Null

$arguments = @(
    "run",
    "--project", $projectPath,
    "--",
    "--appinfo", $appInfoPath,
    "--output", $outputFile
)

if ($AllAppTypes) {
    $arguments += "--all-app-types"
}

dotnet @arguments
