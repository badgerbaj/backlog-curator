[CmdletBinding()]
param(
    [string]$DataPath = (Join-Path $PSScriptRoot "..\data"),
    [string]$RulesPath = (Join-Path $PSScriptRoot "..\rules")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-ProjectPath {
    param([string]$Path)

    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Import-OptionalCsv {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return @(Import-Csv -LiteralPath $Path)
    }

    return @()
}

function Get-Field {
    param(
        [object]$Row,
        [string]$Name
    )

    $property = $Row.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ""
    }

    return ([string]$property.Value).Trim()
}

function New-IndexedRows {
    param(
        [object[]]$Rows,
        [string]$Key
    )

    $index = @{}
    foreach ($row in $Rows) {
        $value = Get-Field $row $Key
        if (-not [string]::IsNullOrWhiteSpace($value) -and -not $index.ContainsKey($value)) {
            $index[$value] = $row
        }
    }

    return $index
}

function Get-ExistingValue {
    param(
        [hashtable]$ExistingRows,
        [string]$AppId,
        [string]$Column
    )

    if (-not $ExistingRows.ContainsKey($AppId)) {
        return ""
    }

    return Get-Field $ExistingRows[$AppId] $Column
}

function Export-Rows {
    param(
        [string]$Path,
        [string[]]$Columns,
        [object[]]$Rows
    )

    if ($Rows.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value (($Columns | ForEach-Object { '"' + $_ + '"' }) -join ",") -Encoding UTF8
        return
    }

    $Rows |
        Select-Object $Columns |
        Sort-Object Title |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

$dataRoot = Resolve-ProjectPath $DataPath
$rulesRoot = Resolve-ProjectPath $RulesPath

$collectionsPath = Join-Path $dataRoot "steam_collections.csv"
$appsPath = Join-Path $dataRoot "steam_apps.csv"
$categoryMapPath = Join-Path $rulesRoot "category-map.csv"

if (-not (Test-Path -LiteralPath $collectionsPath)) {
    throw "Missing $collectionsPath. Run .\scripts\Import-SteamCollections.ps1 first."
}

if (-not (Test-Path -LiteralPath $appsPath)) {
    throw "Missing $appsPath. Run .\scripts\Import-SteamAppInfo.ps1 first."
}

$collections = Import-Csv -LiteralPath $collectionsPath
$appsById = New-IndexedRows (Import-Csv -LiteralPath $appsPath) "AppId"
$categoryMap = Import-Csv -LiteralPath $categoryMapPath

$mapByCollection = @{}
foreach ($mapping in $categoryMap) {
    $steamCollection = Get-Field $mapping "SteamCollection"
    if (-not [string]::IsNullOrWhiteSpace($steamCollection)) {
        $mapByCollection[$steamCollection] = $mapping
    }
}

$targetColumns = @{
    "completed.csv" = @("AppId", "Title", "Rating", "Genres", "Tags", "Series", "ReviewSignal", "Notes")
    "dnf.csv" = @("AppId", "Title", "HoursPlayed", "Genres", "Tags", "Series", "Reason", "Notes")
    "no.csv" = @("AppId", "Title", "Genres", "Tags", "Series", "Reason", "Notes")
    "unplayed.csv" = @("AppId", "Title", "CurrentCategory", "Genres", "Tags", "Series", "PriorEntriesUnfinished", "HoursPlayed", "EstimatedHours", "ReviewSignal", "Notes")
}

$existingByTarget = @{}
foreach ($target in $targetColumns.Keys) {
    $existingByTarget[$target] = New-IndexedRows (Import-OptionalCsv (Join-Path $dataRoot $target)) "AppId"
}

$generated = @{
    "completed.csv" = @()
    "dnf.csv" = @()
    "no.csv" = @()
    "unplayed.csv" = @()
}

$targetPrecedence = @{
    "no.csv" = 100
    "dnf.csv" = 90
    "completed.csv" = 80
    "unplayed.csv" = 10
}

foreach ($row in $collections) {
    $appId = Get-Field $row "AppId"
    if ([string]::IsNullOrWhiteSpace($appId) -or -not $appsById.ContainsKey($appId)) {
        continue
    }

    $candidateMappings = @()
    foreach ($collection in ((Get-Field $row "Collections") -split ";\s*")) {
        if ($mapByCollection.ContainsKey($collection)) {
            $candidateMappings += $mapByCollection[$collection]
        }
    }

    if ($candidateMappings.Count -eq 0) {
        continue
    }

    $selected = $candidateMappings |
        Sort-Object @{ Expression = { $targetPrecedence[(Get-Field $_ "TargetCsv")] }; Descending = $true } |
        Select-Object -First 1

    $target = Get-Field $selected "TargetCsv"
    $category = Get-Field $selected "BacklogCategory"
    $app = $appsById[$appId]
    $existing = $existingByTarget[$target]

    switch ($target) {
        "completed.csv" {
            $generated[$target] += [pscustomobject]@{
                AppId = $appId
                Title = Get-Field $app "Title"
                Rating = Get-ExistingValue $existing $appId "Rating"
                Genres = Get-ExistingValue $existing $appId "Genres"
                Tags = Get-ExistingValue $existing $appId "Tags"
                Series = Get-ExistingValue $existing $appId "Series"
                ReviewSignal = Get-ExistingValue $existing $appId "ReviewSignal"
                Notes = Get-ExistingValue $existing $appId "Notes"
            }
        }
        "dnf.csv" {
            $generated[$target] += [pscustomobject]@{
                AppId = $appId
                Title = Get-Field $app "Title"
                HoursPlayed = Get-ExistingValue $existing $appId "HoursPlayed"
                Genres = Get-ExistingValue $existing $appId "Genres"
                Tags = Get-ExistingValue $existing $appId "Tags"
                Series = Get-ExistingValue $existing $appId "Series"
                Reason = Get-ExistingValue $existing $appId "Reason"
                Notes = Get-ExistingValue $existing $appId "Notes"
            }
        }
        "no.csv" {
            $generated[$target] += [pscustomobject]@{
                AppId = $appId
                Title = Get-Field $app "Title"
                Genres = Get-ExistingValue $existing $appId "Genres"
                Tags = Get-ExistingValue $existing $appId "Tags"
                Series = Get-ExistingValue $existing $appId "Series"
                Reason = Get-ExistingValue $existing $appId "Reason"
                Notes = Get-ExistingValue $existing $appId "Notes"
            }
        }
        "unplayed.csv" {
            $generated[$target] += [pscustomobject]@{
                AppId = $appId
                Title = Get-Field $app "Title"
                CurrentCategory = $category
                Genres = Get-ExistingValue $existing $appId "Genres"
                Tags = Get-ExistingValue $existing $appId "Tags"
                Series = Get-ExistingValue $existing $appId "Series"
                PriorEntriesUnfinished = Get-ExistingValue $existing $appId "PriorEntriesUnfinished"
                HoursPlayed = Get-ExistingValue $existing $appId "HoursPlayed"
                EstimatedHours = Get-ExistingValue $existing $appId "EstimatedHours"
                ReviewSignal = Get-ExistingValue $existing $appId "ReviewSignal"
                Notes = Get-ExistingValue $existing $appId "Notes"
            }
        }
    }
}

$generatedAppIds = @{}
foreach ($target in $targetColumns.Keys) {
    foreach ($row in @($generated[$target])) {
        $appId = Get-Field $row "AppId"
        if (-not [string]::IsNullOrWhiteSpace($appId)) {
            $generatedAppIds[$appId] = $true
        }
    }
}

foreach ($target in $targetColumns.Keys) {
    $preserved = @(
        Import-OptionalCsv (Join-Path $dataRoot $target) |
            Where-Object {
                $appId = Get-Field $_ "AppId"
                [string]::IsNullOrWhiteSpace($appId) -or -not $generatedAppIds.ContainsKey($appId)
            }
    )

    $rows = @($generated[$target]) + $preserved
    Export-Rows -Path (Join-Path $dataRoot $target) -Columns $targetColumns[$target] -Rows $rows
    Write-Host "${target}: $(@($rows).Count) rows"
}
