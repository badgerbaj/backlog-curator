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

function Get-GeneratedMetadataValue {
    param(
        [hashtable]$ExistingRows,
        [hashtable]$MetadataByAppId,
        [string]$AppId,
        [string]$Column
    )

    if ($MetadataByAppId.ContainsKey($AppId)) {
        $metadataValue = Get-Field $MetadataByAppId[$AppId] $Column
        if (-not [string]::IsNullOrWhiteSpace($metadataValue)) {
            return $metadataValue
        }
    }

    return Get-ExistingValue $ExistingRows $AppId $Column
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

function Get-AppMetadataValue {
    param(
        [hashtable]$AppsById,
        [string]$AppId,
        [string]$Column
    )

    if (-not $AppsById.ContainsKey($AppId)) {
        return ""
    }

    return Get-Field $AppsById[$AppId] $Column
}

function Get-CleanTitle {
    param([string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return ""
    }

    $clean = $Title.Trim()
    $clean = $clean -replace '\s+\(\d{4}\)$', ''
    if ($clean -match '^App \d+$') {
        return ""
    }
    return $clean.Trim()
}

function Get-ValidSeriesValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $trimmed = $Value.Trim()
    if ($trimmed -eq "App") {
        return ""
    }

    return $trimmed
}

function Get-SequenceOrdinal {
    param([string]$Title)

    $cleanTitle = Get-CleanTitle -Title $Title
    if ([string]::IsNullOrWhiteSpace($cleanTitle)) {
        return $null
    }

    $matches = [regex]::Matches($cleanTitle, '(?<![A-Za-z])(?:Part\s+)?(II|III|IV|V|VI|VII|VIII|IX|X|[2-9]|[1-9][0-9]+)(?![A-Za-z])', 'IgnoreCase')
    foreach ($match in $matches) {
        $token = $match.Groups[1].Value.ToUpperInvariant()
        $number = $null

        switch ($token) {
            "II" { $number = 2 }
            "III" { $number = 3 }
            "IV" { $number = 4 }
            "V" { $number = 5 }
            "VI" { $number = 6 }
            "VII" { $number = 7 }
            "VIII" { $number = 8 }
            "IX" { $number = 9 }
            "X" { $number = 10 }
            default {
                $parsed = 0
                if ([int]::TryParse($token, [ref]$parsed)) {
                    $number = $parsed
                }
            }
        }

        if ($null -eq $number) {
            continue
        }

        if ($number -gt 1 -and $number -le 15) {
            return $number
        }
    }

    return $null
}

function Get-SeriesFromTitle {
    param([string]$Title)

    $cleanTitle = Get-CleanTitle -Title $Title
    if ([string]::IsNullOrWhiteSpace($cleanTitle)) {
        return ""
    }

    $patterns = @(
        '^(?<series>.+?)\s+(?<seq>II|III|IV|V|VI|VII|VIII|IX|X|[2-9]|[1-9][0-9]+)(?:\b|:)',
        '^(?<series>.+?)\s+(?<seq>II|III|IV|V|VI|VII|VIII|IX|X|[2-9]|[1-9][0-9]+)$'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($cleanTitle, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            continue
        }

        $series = $match.Groups["series"].Value.Trim(" ", ":", "-", [char]0x2013, [char]0x2014)
        if (-not [string]::IsNullOrWhiteSpace($series)) {
            return $series
        }
    }

    return ""
}

function Get-TitleOrdinal {
    param(
        [string]$Title,
        [string]$Series
    )

    $explicit = Get-SequenceOrdinal -Title $Title
    if ($null -ne $explicit) {
        return $explicit
    }

    $cleanTitle = Get-CleanTitle -Title $Title
    if (-not [string]::IsNullOrWhiteSpace($Series) -and $cleanTitle -eq $Series) {
        return 1
    }

    return $null
}

function Get-ResolvedSeries {
    param(
        [hashtable]$AppsById,
        [hashtable]$ExistingSeriesByAppId,
        [object]$Row,
        [string]$AppId
    )

    $rowSeries = Get-ValidSeriesValue (Get-Field $Row "Series")
    if (-not [string]::IsNullOrWhiteSpace($rowSeries)) {
        return $rowSeries
    }

    if ($ExistingSeriesByAppId.ContainsKey($AppId)) {
        return Get-ValidSeriesValue ([string]$ExistingSeriesByAppId[$AppId])
    }

    $franchise = Get-ValidSeriesValue (Get-AppMetadataValue -AppsById $AppsById -AppId $AppId -Column "Franchise")
    if (-not [string]::IsNullOrWhiteSpace($franchise)) {
        return $franchise
    }

    $title = Get-Field $Row "Title"
    $titleSeries = Get-ValidSeriesValue (Get-SeriesFromTitle -Title $title)
    if (-not [string]::IsNullOrWhiteSpace($titleSeries)) {
        return $titleSeries
    }

    return ""
}

function Get-PriorEntriesUnfinishedValue {
    param(
        [object]$Row,
        [string]$AppId,
        [string]$Series,
        [hashtable]$CompletedAppIds,
        [object[]]$OwnedSeriesRows
    )

    if ([string]::IsNullOrWhiteSpace($Series)) {
        return ""
    }

    $title = Get-Field $Row "Title"
    $ordinal = Get-TitleOrdinal -Title $title -Series $Series
    if ($null -eq $ordinal -or $ordinal -le 1) {
        return ""
    }

    $priorOwned = @(
        $OwnedSeriesRows |
            Where-Object {
                $_.Series -eq $Series -and
                $_.AppId -ne $AppId -and
                $null -ne $_.Ordinal -and
                $_.Ordinal -eq ($ordinal - 1)
            }
    )

    if ($priorOwned.Count -eq 0) {
        return ""
    }

    foreach ($prior in $priorOwned) {
        if (-not $CompletedAppIds.ContainsKey($prior.AppId)) {
            return "true"
        }
    }

    return ""
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
$metadataPath = Join-Path $dataRoot "game_metadata.csv"
$categoryMapPath = Join-Path $rulesRoot "category-map.csv"

if (-not (Test-Path -LiteralPath $collectionsPath)) {
    throw "Missing $collectionsPath. Run .\scripts\Import-SteamCollections.ps1 first."
}

if (-not (Test-Path -LiteralPath $appsPath)) {
    throw "Missing $appsPath. Run .\scripts\Import-SteamAppInfo.ps1 first."
}

$collections = Import-Csv -LiteralPath $collectionsPath
$appsById = New-IndexedRows (Import-Csv -LiteralPath $appsPath) "AppId"
$metadataByAppId = New-IndexedRows (Import-OptionalCsv $metadataPath) "AppId"
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

$existingSeriesByAppId = @{}
$allExistingRowsByAppId = @{}
foreach ($target in $existingByTarget.Keys) {
    foreach ($appId in $existingByTarget[$target].Keys) {
        if (-not $allExistingRowsByAppId.ContainsKey($appId)) {
            $allExistingRowsByAppId[$appId] = $existingByTarget[$target][$appId]
        }

        $series = Get-ExistingValue $existingByTarget[$target] $appId "Series"
        $series = Get-ValidSeriesValue $series
        if (-not [string]::IsNullOrWhiteSpace($series) -and -not $existingSeriesByAppId.ContainsKey($appId)) {
            $existingSeriesByAppId[$appId] = $series
        }
    }
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
                Genres = Get-GeneratedMetadataValue $existing $metadataByAppId $appId "Genres"
                Tags = Get-GeneratedMetadataValue $existing $metadataByAppId $appId "Tags"
                Series = Get-ExistingValue $existing $appId "Series"
                ReviewSignal = Get-GeneratedMetadataValue $existing $metadataByAppId $appId "ReviewSignal"
                Notes = Get-ExistingValue $existing $appId "Notes"
            }
        }
        "dnf.csv" {
            $generated[$target] += [pscustomobject]@{
                AppId = $appId
                Title = $title
                HoursPlayed = if ($playedMinutesByAppId.ContainsKey($appId)) { Format-HoursPlayed $playedMinutesByAppId[$appId] } else { Get-ExistingValue $existing $appId "HoursPlayed" }
                Genres = Get-GeneratedMetadataValue $existing $metadataByAppId $appId "Genres"
                Tags = Get-GeneratedMetadataValue $existing $metadataByAppId $appId "Tags"
                Series = Get-ExistingValue $existing $appId "Series"
                Reason = Get-ExistingValue $existing $appId "Reason"
                Notes = Get-ExistingValue $existing $appId "Notes"
            }
        }
        "no.csv" {
            $generated[$target] += [pscustomobject]@{
                AppId = $appId
                Title = $title
                Genres = Get-GeneratedMetadataValue $existing $metadataByAppId $appId "Genres"
                Tags = Get-GeneratedMetadataValue $existing $metadataByAppId $appId "Tags"
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
                Genres = Get-GeneratedMetadataValue $existing $metadataByAppId $appId "Genres"
                Tags = Get-GeneratedMetadataValue $existing $metadataByAppId $appId "Tags"
                Series = Get-ExistingValue $existing $appId "Series"
                PriorEntriesUnfinished = ""
                HoursPlayed = if ($playedMinutesByAppId.ContainsKey($appId)) { Format-HoursPlayed $playedMinutesByAppId[$appId] } else { Get-ExistingValue $existing $appId "HoursPlayed" }
                EstimatedHours = Get-GeneratedMetadataValue $existing $metadataByAppId $appId "EstimatedHours"
                ReviewSignal = Get-GeneratedMetadataValue $existing $metadataByAppId $appId "ReviewSignal"
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
        Genres = Get-GeneratedMetadataValue $existingUnplayed $metadataByAppId $appId "Genres"
        Tags = Get-GeneratedMetadataValue $existingUnplayed $metadataByAppId $appId "Tags"
        Series = Get-ExistingValue $existingUnplayed $appId "Series"
        PriorEntriesUnfinished = ""
        HoursPlayed = "0"
        EstimatedHours = Get-GeneratedMetadataValue $existingUnplayed $metadataByAppId $appId "EstimatedHours"
        ReviewSignal = Get-GeneratedMetadataValue $existingUnplayed $metadataByAppId $appId "ReviewSignal"
        Notes = Get-ExistingValue $existingUnplayed $appId "Notes"
    }
}

$completedAppIds = @{}
foreach ($row in @($existingByTarget["completed.csv"].Values) + @($generated["completed.csv"])) {
    $appId = Get-Field $row "AppId"
    if (-not [string]::IsNullOrWhiteSpace($appId)) {
        $completedAppIds[$appId] = $true
    }
}

$ownedContextIds = @(
    ($ownedAppIds + @(
        foreach ($target in @("completed.csv", "dnf.csv", "no.csv", "backlog.csv", "unplayed.csv")) {
            foreach ($row in @($generated[$target])) {
                $appId = Get-Field $row "AppId"
                if (-not [string]::IsNullOrWhiteSpace($appId)) {
                    $appId
                }
            }
        }
    )) | Sort-Object -Unique
)

$ownedSeriesRows = @(
    foreach ($appId in $ownedContextIds) {
        $title = Get-AppTitle -AppsById $appsById -ExistingRows $allExistingRowsByAppId -AppId $appId
        $series = ""
        if ($existingSeriesByAppId.ContainsKey($appId)) {
            $series = Get-ValidSeriesValue ([string]$existingSeriesByAppId[$appId])
        }
        if ([string]::IsNullOrWhiteSpace($series)) {
            $series = Get-ValidSeriesValue (Get-AppMetadataValue -AppsById $appsById -AppId $appId -Column "Franchise")
        }

        [pscustomobject]@{
            AppId = $appId
            Title = $title
            Series = $series
            Ordinal = Get-TitleOrdinal -Title $title -Series $series
        }
    }
)

foreach ($target in @("completed.csv", "dnf.csv", "no.csv", "backlog.csv", "unplayed.csv")) {
    foreach ($row in @($generated[$target])) {
        $appId = Get-Field $row "AppId"
        if ([string]::IsNullOrWhiteSpace($appId)) {
            continue
        }

        $series = Get-ResolvedSeries -AppsById $appsById -ExistingSeriesByAppId $existingSeriesByAppId -Row $row -AppId $appId
        $row.PSObject.Properties["Series"].Value = $series

        if ($target -in @("backlog.csv", "unplayed.csv")) {
            $row.PSObject.Properties["PriorEntriesUnfinished"].Value = (
                Get-PriorEntriesUnfinishedValue -Row $row -AppId $appId -Series $series -CompletedAppIds $completedAppIds -OwnedSeriesRows $ownedSeriesRows
            )
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
