[CmdletBinding()]
param(
    [string]$DataPath = (Join-Path $PSScriptRoot "..\data"),
    [string]$RulesPath = (Join-Path $PSScriptRoot "..\rules"),
    [string]$SteamPath,
    [string]$AccountId
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

function Read-VdfTokens {
    param([string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw
    $matches = [regex]::Matches($text, '"((?:\\.|[^"\\])*)"|([{}])')
    foreach ($match in $matches) {
        if ($match.Groups[2].Success) {
            [pscustomobject]@{ Kind = $match.Groups[2].Value; Value = $match.Groups[2].Value }
        }
        else {
            $value = $match.Groups[1].Value -replace '\\"', '"' -replace '\\\\', '\'
            [pscustomobject]@{ Kind = "string"; Value = $value }
        }
    }
}

function ConvertFrom-SimpleVdf {
    param([string]$Path)

    $root = [ordered]@{}
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($root)
    $pendingKey = $null
    $lastKey = $null

    foreach ($token in (Read-VdfTokens -Path $Path)) {
        switch ($token.Kind) {
            "string" {
                if ($null -eq $pendingKey) {
                    $pendingKey = $token.Value
                    $lastKey = $token.Value
                }
                else {
                    $stack.Peek()[$pendingKey] = $token.Value
                    $pendingKey = $null
                }
            }
            "{" {
                if ($null -eq $pendingKey) {
                    $pendingKey = $lastKey
                }

                $child = [ordered]@{}
                $stack.Peek()[$pendingKey] = $child
                $stack.Push($child)
                $pendingKey = $null
            }
            "}" {
                if ($stack.Count -gt 1) {
                    [void]$stack.Pop()
                }
                $pendingKey = $null
            }
        }
    }

    return $root
}

function Get-NestedValue {
    param(
        [object]$Object,
        [string[]]$Path
    )

    $current = $Object
    foreach ($part in $Path) {
        if ($null -eq $current -or -not $current.Contains($part)) {
            return $null
        }
        $current = $current[$part]
    }

    return $current
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

function Get-AppTitle {
    param(
        [hashtable]$AppsById,
        [hashtable]$ExistingRows,
        [string]$AppId
    )

    if ($AppsById.ContainsKey($AppId)) {
        $title = Get-Field $AppsById[$AppId] "Title"
        if (-not [string]::IsNullOrWhiteSpace($title)) {
            return $title
        }
    }

    $existingTitle = Get-ExistingValue $ExistingRows $AppId "Title"
    if (-not [string]::IsNullOrWhiteSpace($existingTitle)) {
        return $existingTitle
    }

    return "App $AppId"
}

function Get-AccountId {
    param(
        [string]$ExplicitAccountId,
        [object[]]$Collections
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitAccountId)) {
        return $ExplicitAccountId
    }

    $candidate = @(
        $Collections |
            Select-Object -ExpandProperty AccountId -Unique |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -First 1
    )

    if ($candidate.Count -gt 0) {
        return [string]$candidate[0]
    }

    throw "Could not infer Steam account id. Pass -AccountId explicitly."
}

function Get-PlayedMinutesByAppId {
    param([string]$Path)

    $vdf = ConvertFrom-SimpleVdf -Path $Path
    $apps = Get-NestedValue $vdf @("UserLocalConfigStore", "Software", "Valve", "Steam", "apps")
    $minutes = @{}

    if ($null -eq $apps) {
        return $minutes
    }

    foreach ($appId in $apps.Keys) {
        $app = $apps[$appId]
        if ($app -is [System.Collections.IDictionary] -and $app.Contains("Playtime")) {
            $value = 0
            if ([int]::TryParse([string]$app["Playtime"], [ref]$value)) {
                $minutes[[string]$appId] = $value
            }
        }
    }

    return $minutes
}

function Get-UnplayedOverrides {
    param([string]$Path)

    $result = @{
        Added = @()
        Removed = @()
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    $entries = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    foreach ($entry in $entries) {
        if ($entry.Count -lt 2) {
            continue
        }

        $record = $entry[1]
        if (-not $record.PSObject.Properties["value"]) {
            continue
        }

        $collection = $record.value | ConvertFrom-Json
        if (-not $collection.PSObject.Properties["name"] -or $collection.name -ne "Unplayed") {
            continue
        }

        $result.Added = @($collection.added | ForEach-Object { [string]$_ })
        $result.Removed = @($collection.removed | ForEach-Object { [string]$_ })
        break
    }

    return $result
}

function Get-OwnedAppIds {
    param([string]$LibraryCachePath)

    if (-not (Test-Path -LiteralPath $LibraryCachePath)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $LibraryCachePath -Filter "*.json" |
            ForEach-Object { $_.BaseName } |
            Where-Object { $_ -match "^\d+$" -and $_ -ne "0" } |
            Sort-Object -Unique
    )
}

function Format-HoursPlayed {
    param([int]$Minutes)

    if ($Minutes -le 0) {
        return "0"
    }

    return ([Math]::Round($Minutes / 60.0, 1)).ToString("0.0", [CultureInfo]::InvariantCulture)
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
$steamRoot = Get-SteamPath -ExplicitPath $SteamPath
$steamAccountId = Get-AccountId -ExplicitAccountId $AccountId -Collections $collections
$localConfigPath = Join-Path $steamRoot "userdata\$steamAccountId\config\localconfig.vdf"
$libraryCachePath = Join-Path $steamRoot "userdata\$steamAccountId\config\librarycache"
$cloudStoragePath = Join-Path $steamRoot "userdata\$steamAccountId\config\cloudstorage\cloud-storage-namespace-1.json"
$playedMinutesByAppId = Get-PlayedMinutesByAppId -Path $localConfigPath
$ownedAppIds = Get-OwnedAppIds -LibraryCachePath $libraryCachePath
$unplayedOverrides = Get-UnplayedOverrides -Path $cloudStoragePath
$noAppIds = @{}

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
    "backlog.csv" = @("AppId", "Title", "CurrentCategory", "Genres", "Tags", "Series", "PriorEntriesUnfinished", "HoursPlayed", "EstimatedHours", "ReviewSignal", "Notes")
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
    "backlog.csv" = @()
    "unplayed.csv" = @()
}

$targetPrecedence = @{
    "no.csv" = 100
    "dnf.csv" = 90
    "completed.csv" = 80
    "backlog.csv" = 20
    "unplayed.csv" = 10
}

foreach ($row in $collections) {
    $appId = Get-Field $row "AppId"
    if ([string]::IsNullOrWhiteSpace($appId)) {
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
    $existing = $existingByTarget[$target]
    $title = Get-AppTitle -AppsById $appsById -ExistingRows $existing -AppId $appId

    if ($target -eq "no.csv") {
        $noAppIds[$appId] = $true
    }

    switch ($target) {
        "completed.csv" {
            $generated[$target] += [pscustomobject]@{
                AppId = $appId
                Title = $title
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
                Title = $title
                HoursPlayed = if ($playedMinutesByAppId.ContainsKey($appId)) { Format-HoursPlayed $playedMinutesByAppId[$appId] } else { Get-ExistingValue $existing $appId "HoursPlayed" }
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
                Title = $title
                Genres = Get-ExistingValue $existing $appId "Genres"
                Tags = Get-ExistingValue $existing $appId "Tags"
                Series = Get-ExistingValue $existing $appId "Series"
                Reason = Get-ExistingValue $existing $appId "Reason"
                Notes = Get-ExistingValue $existing $appId "Notes"
            }
        }
        "backlog.csv" {
            $generated[$target] += [pscustomobject]@{
                AppId = $appId
                Title = $title
                CurrentCategory = $category
                Genres = Get-ExistingValue $existing $appId "Genres"
                Tags = Get-ExistingValue $existing $appId "Tags"
                Series = Get-ExistingValue $existing $appId "Series"
                PriorEntriesUnfinished = Get-ExistingValue $existing $appId "PriorEntriesUnfinished"
                HoursPlayed = if ($playedMinutesByAppId.ContainsKey($appId)) { Format-HoursPlayed $playedMinutesByAppId[$appId] } else { Get-ExistingValue $existing $appId "HoursPlayed" }
                EstimatedHours = Get-ExistingValue $existing $appId "EstimatedHours"
                ReviewSignal = Get-ExistingValue $existing $appId "ReviewSignal"
                Notes = Get-ExistingValue $existing $appId "Notes"
            }
        }
    }
}

$existingUnplayed = $existingByTarget["unplayed.csv"]
$computedUnplayedIds = @(
    ($ownedAppIds | Where-Object {
        -not $playedMinutesByAppId.ContainsKey($_) -and
        -not $noAppIds.ContainsKey($_) -and
        $unplayedOverrides.Removed -notcontains $_
    }) + $unplayedOverrides.Added |
        Sort-Object -Unique
)

foreach ($appId in $computedUnplayedIds) {
    $generated["unplayed.csv"] += [pscustomobject]@{
        AppId = $appId
        Title = Get-AppTitle -AppsById $appsById -ExistingRows $existingUnplayed -AppId $appId
        CurrentCategory = ""
        Genres = Get-ExistingValue $existingUnplayed $appId "Genres"
        Tags = Get-ExistingValue $existingUnplayed $appId "Tags"
        Series = Get-ExistingValue $existingUnplayed $appId "Series"
        PriorEntriesUnfinished = Get-ExistingValue $existingUnplayed $appId "PriorEntriesUnfinished"
        HoursPlayed = "0"
        EstimatedHours = Get-ExistingValue $existingUnplayed $appId "EstimatedHours"
        ReviewSignal = Get-ExistingValue $existingUnplayed $appId "ReviewSignal"
        Notes = Get-ExistingValue $existingUnplayed $appId "Notes"
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
