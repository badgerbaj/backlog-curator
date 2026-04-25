[CmdletBinding()]
param(
    [string]$DataPath = (Join-Path $PSScriptRoot "..\data"),
    [int]$RefreshDays = 30,
    [int]$ThrottleMilliseconds = 500,
    [switch]$Force,
    [switch]$SkipSteam,
    [switch]$SkipHltb,
    [int]$MaxApps
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

function Export-TargetCsv {
    param(
        [string]$Path,
        [object[]]$Rows
    )

    if (@($Rows).Count -eq 0) {
        return
    }

    $rowArray = @($Rows)
    $columns = @($rowArray[0].PSObject.Properties.Name)
    $rowArray |
        Select-Object $columns |
        Sort-Object Title |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Get-TimestampUtc {
    return (Get-Date).ToUniversalTime().ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-WebHeaders {
    return @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
        "Accept-Language" = "en-US,en;q=0.9"
    }
}

function Invoke-JsonRequest {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [object]$Body,
        [hashtable]$Headers,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
    )

    $request = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        ErrorAction = "Stop"
    }

    if ($PSBoundParameters.ContainsKey("Body")) {
        $request.ContentType = "application/json"
        $request.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
    }

    if ($PSBoundParameters.ContainsKey("WebSession")) {
        $request.WebSession = $WebSession
    }

    return Invoke-RestMethod @request
}

function Invoke-TextRequest {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
    )

    $request = @{
        Uri = $Uri
        Headers = $Headers
        UseBasicParsing = $true
        ErrorAction = "Stop"
    }

    if ($PSBoundParameters.ContainsKey("WebSession")) {
        $request.WebSession = $WebSession
    }

    return (Invoke-WebRequest @request).Content
}

function Normalize-Title {
    param([string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return ""
    }

    $text = $Title.ToLowerInvariant()
    $text = $text -replace '[\u2122\u00ae\u00a9]', ' '
    $text = $text -replace '\s+\(\d{4}\)$', ' '
    $text = $text -replace '\b(game of the year|goty|definitive edition|complete edition|enhanced edition|director''s cut|remastered|redux|ultimate edition|hd|special edition)\b', ' '
    $text = $text -replace '[^a-z0-9]+', ' '
    $text = $text -replace '\s+', ' '
    return $text.Trim()
}

function Get-HltbBucket {
    param([double]$Hours)

    if ($Hours -le 0) { return "" }
    if ($Hours -lt 12) { return "Short" }
    if ($Hours -lt 25) { return "Medium" }
    if ($Hours -lt 50) { return "Long" }
    return "Huge"
}

function Convert-HltbSecondsToHours {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [ref]$number)) {
        return ""
    }

    if ($number -ge 1000) {
        $number = $number / 3600.0
    }

    return ([Math]::Round($number, 1)).ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Split-HltbSearchTerms {
    param([string]$Title)

    $normalized = Normalize-Title -Title $Title
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return @()
    }

    return @($normalized -split '\s+' | Where-Object { $_.Length -gt 0 })
}

function Select-HltbMatch {
    param(
        [object[]]$Candidates,
        [string]$Title,
        [string]$AppId
    )

    if ($Candidates.Count -eq 0) {
        return $null
    }

    $normalizedTitle = Normalize-Title -Title $Title

    $scored = foreach ($candidate in $Candidates) {
        $candidateName = ""
        if ($candidate.PSObject.Properties["game_name"]) {
            $candidateName = [string]$candidate.game_name
        }
        elseif ($candidate.PSObject.Properties["name"]) {
            $candidateName = [string]$candidate.name
        }

        $normalizedCandidate = Normalize-Title -Title $candidateName
        $score = 0.0

        if ($candidate.PSObject.Properties["profile_steam"] -and [string]$candidate.profile_steam -eq $AppId) {
            $score += 100.0
        }

        if ($normalizedCandidate -eq $normalizedTitle) {
            $score += 50.0
        }
        elseif ($normalizedCandidate.StartsWith($normalizedTitle) -or $normalizedTitle.StartsWith($normalizedCandidate)) {
            $score += 20.0
        }

        if ($candidate.PSObject.Properties["similarity"]) {
            $parsedSimilarity = 0.0
            if ([double]::TryParse([string]$candidate.similarity, [ref]$parsedSimilarity)) {
                $score += ($parsedSimilarity * 10.0)
            }
        }

        [pscustomobject]@{
            Score = $score
            Candidate = $candidate
        }
    }

    return ($scored | Sort-Object Score -Descending | Select-Object -First 1).Candidate
}

function Get-SteamStoreMetadata {
    param(
        [string]$AppId,
        [hashtable]$Headers
    )

    $uri = "https://store.steampowered.com/api/appdetails?appids=$AppId&cc=us&l=english"
    $response = Invoke-JsonRequest -Uri $uri -Headers $Headers
    $property = $response.PSObject.Properties[$AppId]
    if ($null -eq $property -or -not $property.Value.success) {
        return $null
    }

    $data = $property.Value.data
    $genres = @()
    if ($data.PSObject.Properties["genres"]) {
        $genres = @($data.genres | ForEach-Object { [string]$_.description } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $tags = @()
    try {
        $html = Invoke-TextRequest -Uri "https://store.steampowered.com/app/$AppId/?cc=us&l=english" -Headers $Headers
        $matches = [regex]::Matches($html, 'class="app_tag[^"]*"[^>]*>\s*(?<tag>[^<]+?)\s*</a>', 'IgnoreCase')
        $tags = @(
            $matches |
                ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups["tag"].Value).Trim() } |
                Where-Object { $_.Length -gt 0 -and $_ -ne "+" } |
                Select-Object -Unique |
                Select-Object -First 8
        )
    }
    catch {
        $tags = @()
    }

    return [pscustomobject]@{
        Genres = ($genres -join "; ")
        Tags = ($tags -join "; ")
        SteamStoreLastFetchedUtc = Get-TimestampUtc
    }
}

function Get-SteamReviewMetadata {
    param(
        [string]$AppId,
        [hashtable]$Headers
    )

    $uri = "https://store.steampowered.com/appreviews/${AppId}?json=1&language=all&purchase_type=steam&review_type=all&filter=all&day_range=365&num_per_page=20&cursor=*"
    $response = Invoke-JsonRequest -Uri $uri -Headers $Headers
    if ($null -eq $response -or $response.success -ne 1 -or -not $response.PSObject.Properties["query_summary"]) {
        return $null
    }

    $summary = $response.query_summary
    return [pscustomobject]@{
        ReviewSignal = [string]$summary.review_score_desc
        ReviewCount = [string]$summary.total_reviews
    }
}

function Get-HltbMetadata {
    param(
        [string]$Title,
        [string]$AppId,
        [hashtable]$Headers,
        [hashtable]$Context,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
    )

    $terms = @(Split-HltbSearchTerms -Title $Title)
    if (@($terms).Count -eq 0) {
        return $null
    }

    $headers = @{}
    foreach ($key in $Headers.Keys) {
        $headers[$key] = $Headers[$key]
    }
    $headers["Origin"] = "https://howlongtobeat.com"
    $headers["Referer"] = "https://howlongtobeat.com/"
    $headers["x-auth-token"] = $Context.Token
    if (-not [string]::IsNullOrWhiteSpace($Context.HpKey)) {
        $headers["x-hp-key"] = $Context.HpKey
    }
    if (-not [string]::IsNullOrWhiteSpace($Context.HpVal)) {
        $headers["x-hp-val"] = $Context.HpVal
    }

    $body = @{
        searchType = "games"
        searchTerms = $terms
        searchPage = 1
        size = 20
        searchOptions = @{
            games = @{
                userId = 0
                platform = ""
                sortCategory = "popular"
                rangeCategory = "main"
                rangeTime = @{
                    min = 0
                    max = 0
                }
                gameplay = @{
                    perspective = ""
                    flow = ""
                    genre = ""
                    difficulty = ""
                }
                rangeYear = @{
                    min = ""
                    max = ""
                }
                modifier = ""
            }
            users = @{
                sortCategory = "postcount"
            }
            lists = @{
                sortCategory = "follows"
            }
            filter = ""
            sort = 0
            randomizer = 0
        }
        useCache = $true
    }

    $response = Invoke-JsonRequest -Uri "https://howlongtobeat.com/api/find" -Method "POST" -Body $body -Headers $headers -WebSession $WebSession
    if ($null -eq $response -or -not $response.PSObject.Properties["data"]) {
        return $null
    }

    $candidate = Select-HltbMatch -Candidates @($response.data) -Title $Title -AppId $AppId
    if ($null -eq $candidate) {
        return $null
    }

    $main = Convert-HltbSecondsToHours -Value $candidate.comp_main
    $plus = Convert-HltbSecondsToHours -Value $candidate.comp_plus
    $completionist = Convert-HltbSecondsToHours -Value $candidate.comp_100

    $matchName = ""
    if ($candidate.PSObject.Properties["game_name"]) {
        $matchName = [string]$candidate.game_name
    }
    elseif ($candidate.PSObject.Properties["name"]) {
        $matchName = [string]$candidate.name
    }

    $bucket = ""
    if (-not [string]::IsNullOrWhiteSpace($main)) {
        $hours = 0.0
        if ([double]::TryParse($main, [ref]$hours)) {
            $bucket = Get-HltbBucket -Hours $hours
        }
    }

    return [pscustomobject]@{
        EstimatedHours = $main
        EstimatedHoursBucket = $bucket
        HltbMainHours = $main
        HltbPlusHours = $plus
        HltbCompletionistHours = $completionist
        HltbMatch = $matchName
        HltbLastFetchedUtc = Get-TimestampUtc
    }
}

function Get-HltbSearchContext {
    param(
        [hashtable]$Headers,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
    )

    [void](Invoke-TextRequest -Uri "https://howlongtobeat.com/" -Headers $Headers -WebSession $WebSession)
    $response = Invoke-JsonRequest -Uri ("https://howlongtobeat.com/api/find/init?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Headers $Headers -WebSession $WebSession
    if ($null -eq $response -or -not $response.PSObject.Properties["token"]) {
        throw "HLTB search init did not return an auth token."
    }

    return @{
        Token = [string]$response.token
        HpKey = if ($response.PSObject.Properties["hpKey"]) { [string]$response.hpKey } else { "" }
        HpVal = if ($response.PSObject.Properties["hpVal"]) { [string]$response.hpVal } else { "" }
    }
}

function Needs-Refresh {
    param(
        [object]$ExistingRow,
        [datetime]$CutoffUtc,
        [bool]$ForceRefresh
    )

    if ($ForceRefresh -or $null -eq $ExistingRow) {
        return $true
    }

    $lastUpdated = Get-Field $ExistingRow "LastUpdatedUtc"
    if ([string]::IsNullOrWhiteSpace($lastUpdated)) {
        return $true
    }

    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($lastUpdated, [ref]$parsed)) {
        return $true
    }

    if ($parsed.ToUniversalTime() -lt $CutoffUtc) {
        return $true
    }

    foreach ($column in @("Genres", "ReviewSignal", "EstimatedHours")) {
        if ([string]::IsNullOrWhiteSpace((Get-Field $ExistingRow $column))) {
            return $true
        }
    }

    return $false
}

function Get-ResolvedValue {
    param(
        [object]$ExistingRow,
        [object]$NewData,
        [string]$Column
    )

    if ($null -ne $NewData) {
        $newValue = Get-Field $NewData $Column
        if (-not [string]::IsNullOrWhiteSpace($newValue)) {
            return $newValue
        }
    }

    if ($null -ne $ExistingRow) {
        return Get-Field $ExistingRow $Column
    }

    return ""
}

$dataRoot = Resolve-ProjectPath $DataPath
$cachePath = Join-Path $dataRoot "game_metadata.csv"
$appsPath = Join-Path $dataRoot "steam_apps.csv"

$cacheRows = Import-OptionalCsv $cachePath
$cacheById = New-IndexedRows $cacheRows "AppId"
$appsById = New-IndexedRows (Import-OptionalCsv $appsPath) "AppId"

$sourceRows = @()
foreach ($file in @("backlog.csv", "unplayed.csv", "wishlist.csv", "completed.csv", "dnf.csv", "no.csv")) {
    $sourceRows += Import-OptionalCsv (Join-Path $dataRoot $file)
}

$candidateAppIds = New-Object System.Collections.Generic.List[string]
foreach ($row in $sourceRows) {
    $appId = Get-Field $row "AppId"
    if (-not [string]::IsNullOrWhiteSpace($appId) -and -not $candidateAppIds.Contains($appId)) {
        $candidateAppIds.Add($appId)
    }
}

if ($MaxApps -gt 0) {
    $candidateAppIds = New-Object System.Collections.Generic.List[string]
    foreach ($appId in @($sourceRows | Select-Object -ExpandProperty AppId -Unique | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First $MaxApps)) {
        if (-not $candidateAppIds.Contains($appId)) {
            $candidateAppIds.Add([string]$appId)
        }
    }
}

$headers = Get-WebHeaders
$cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-1 * $RefreshDays)
$updatedRows = New-Object System.Collections.Generic.List[object]
$hltbContext = $null
$hltbSession = $null

if (-not $SkipHltb) {
    try {
        $hltbSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $hltbContext = Get-HltbSearchContext -Headers $headers -WebSession $hltbSession
    }
    catch {
        Write-Warning "HLTB auth init failed: $($_.Exception.Message)"
    }
}

foreach ($appId in $candidateAppIds) {
    $existing = if ($cacheById.ContainsKey($appId)) { $cacheById[$appId] } else { $null }
    $title = ""

    foreach ($row in $sourceRows) {
        if ((Get-Field $row "AppId") -eq $appId) {
            $title = Get-Field $row "Title"
            if (-not [string]::IsNullOrWhiteSpace($title)) {
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($title) -and $appsById.ContainsKey($appId)) {
        $title = Get-Field $appsById[$appId] "Title"
    }

    if ([string]::IsNullOrWhiteSpace($title) -and $null -ne $existing) {
        $title = Get-Field $existing "Title"
    }

    $steamData = $null
    $reviewData = $null
    $hltbData = $null

    if (Needs-Refresh -ExistingRow $existing -CutoffUtc $cutoffUtc -ForceRefresh $Force.IsPresent) {
        Write-Host "Refreshing $appId - $title"

        if (-not $SkipSteam) {
            try {
                $steamData = Get-SteamStoreMetadata -AppId $appId -Headers $headers
            }
            catch {
                Write-Warning "Steam store metadata failed for $appId ($title): $($_.Exception.Message)"
            }

            Start-Sleep -Milliseconds $ThrottleMilliseconds

            try {
                $reviewData = Get-SteamReviewMetadata -AppId $appId -Headers $headers
            }
            catch {
                Write-Warning "Steam review metadata failed for $appId ($title): $($_.Exception.Message)"
            }
        }

        if (-not $SkipHltb) {
            Start-Sleep -Milliseconds $ThrottleMilliseconds

            try {
                if ($null -ne $hltbContext) {
                    $hltbData = Get-HltbMetadata -Title $title -AppId $appId -Headers $headers -Context $hltbContext -WebSession $hltbSession
                }
            }
            catch {
                Write-Warning "HLTB metadata failed for $appId ($title): $($_.Exception.Message)"
            }
        }
    }

    $row = [pscustomobject]@{
        AppId = $appId
        Title = $title
        Genres = Get-ResolvedValue -ExistingRow $existing -NewData $steamData -Column "Genres"
        Tags = Get-ResolvedValue -ExistingRow $existing -NewData $steamData -Column "Tags"
        ReviewSignal = Get-ResolvedValue -ExistingRow $existing -NewData $reviewData -Column "ReviewSignal"
        ReviewCount = Get-ResolvedValue -ExistingRow $existing -NewData $reviewData -Column "ReviewCount"
        EstimatedHours = Get-ResolvedValue -ExistingRow $existing -NewData $hltbData -Column "EstimatedHours"
        EstimatedHoursBucket = Get-ResolvedValue -ExistingRow $existing -NewData $hltbData -Column "EstimatedHoursBucket"
        HltbMainHours = Get-ResolvedValue -ExistingRow $existing -NewData $hltbData -Column "HltbMainHours"
        HltbPlusHours = Get-ResolvedValue -ExistingRow $existing -NewData $hltbData -Column "HltbPlusHours"
        HltbCompletionistHours = Get-ResolvedValue -ExistingRow $existing -NewData $hltbData -Column "HltbCompletionistHours"
        HltbMatch = Get-ResolvedValue -ExistingRow $existing -NewData $hltbData -Column "HltbMatch"
        SteamStoreLastFetchedUtc = Get-ResolvedValue -ExistingRow $existing -NewData $steamData -Column "SteamStoreLastFetchedUtc"
        HltbLastFetchedUtc = Get-ResolvedValue -ExistingRow $existing -NewData $hltbData -Column "HltbLastFetchedUtc"
        LastUpdatedUtc = Get-TimestampUtc
    }

    $updatedRows.Add($row)
}

$cacheColumns = @(
    "AppId",
    "Title",
    "Genres",
    "Tags",
    "ReviewSignal",
    "ReviewCount",
    "EstimatedHours",
    "EstimatedHoursBucket",
    "HltbMainHours",
    "HltbPlusHours",
    "HltbCompletionistHours",
    "HltbMatch",
    "SteamStoreLastFetchedUtc",
    "HltbLastFetchedUtc",
    "LastUpdatedUtc"
)

Export-Rows -Path $cachePath -Columns $cacheColumns -Rows $updatedRows.ToArray()
Write-Host "Wrote $cachePath"

$metadataByAppId = New-IndexedRows $updatedRows.ToArray() "AppId"
foreach ($targetFile in @("backlog.csv", "unplayed.csv", "wishlist.csv", "completed.csv", "dnf.csv", "no.csv")) {
    $path = Join-Path $dataRoot $targetFile
    $rows = @(Import-OptionalCsv $path)
    if (@($rows).Count -eq 0) {
        continue
    }

    foreach ($row in $rows) {
        $appId = Get-Field $row "AppId"
        if ([string]::IsNullOrWhiteSpace($appId) -or -not $metadataByAppId.ContainsKey($appId)) {
            continue
        }

        $metadata = $metadataByAppId[$appId]
        foreach ($column in @("Genres", "Tags", "ReviewSignal", "EstimatedHours")) {
            $property = $row.PSObject.Properties[$column]
            if ($null -eq $property) {
                continue
            }

            $value = Get-Field $metadata $column
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $property.Value = $value
            }
        }
    }

    Export-TargetCsv -Path $path -Rows $rows
    Write-Host "Applied metadata to $targetFile"
}
