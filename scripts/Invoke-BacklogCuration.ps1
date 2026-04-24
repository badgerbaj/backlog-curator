[CmdletBinding()]
param(
    [string]$DataPath = (Join-Path $PSScriptRoot "..\data"),
    [string]$RulesPath = (Join-Path $PSScriptRoot "..\rules"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\outputs\recommendations.md")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-ProjectPath {
    param([string]$Path)

    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Import-GameCsv {
    param(
        [string]$Path,
        [string]$Source
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $rows = @(Import-Csv -LiteralPath $Path)
    foreach ($row in $rows) {
        $row | Add-Member -NotePropertyName Source -NotePropertyValue $Source -Force
    }

    return @($rows)
}

function Get-Field {
    param(
        [object]$Row,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Row.PSObject.Properties[$name]
        if ($null -ne $property) {
            $value = [string]$property.Value
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value.Trim()
            }
        }
    }

    return ""
}

function ConvertTo-BooleanSignal {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "y", "unfinished", "prior unfinished")
}

function ConvertTo-Number {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $number = 0.0
    if ([double]::TryParse($Value, [ref]$number)) {
        return $number
    }

    if ($Value -match "(\d+(\.\d+)?)") {
        return [double]$Matches[1]
    }

    return $null
}

function Split-Tags {
    param([string[]]$Values)

    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($value in $Values) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        foreach ($token in ($value -split "[,;/|]")) {
            $clean = $token.Trim().ToLowerInvariant()
            if ($clean.Length -gt 1) {
                $tokens.Add($clean)
            }
        }
    }

    return @($tokens | Select-Object -Unique)
}

function Add-WeightedToken {
    param(
        [hashtable]$Table,
        [string]$Token,
        [double]$Weight
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return
    }

    if (-not $Table.ContainsKey($Token)) {
        $Table[$Token] = 0.0
    }

    $Table[$Token] = [double]$Table[$Token] + $Weight
}

function Read-MarkdownRules {
    param([string]$RulesPath)

    $rules = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $RulesPath -Filter "*.md" | Where-Object {
        $_.Name -in @("taste-profile.md", "friction-rules.md")
    })

    foreach ($file in $files) {
        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
            if ($line -notmatch "^\s*\|") {
                continue
            }

            $trimmed = $line.Trim()
            if ($trimmed -match "^\|\s*-") {
                continue
            }

            $cells = @($trimmed.Trim("|").Split("|") | ForEach-Object { $_.Trim() })
            if ($cells.Count -lt 4 -or $cells[0] -eq "Signal") {
                continue
            }

            $weight = 0
            if (-not [int]::TryParse($cells[1], [ref]$weight)) {
                continue
            }

            $keywords = @(
                $cells[2].Split(",") |
                    ForEach-Object { $_.Trim().ToLowerInvariant() } |
                    Where-Object { $_.Length -gt 0 }
            )

            $rules.Add([pscustomobject]@{
                Signal = $cells[0]
                Weight = $weight
                Keywords = $keywords
                Why = $cells[3]
                Source = $file.Name
            })
        }
    }

    return $rules.ToArray()
}

function Get-ReviewScore {
    param([string]$ReviewSignal)

    if ([string]::IsNullOrWhiteSpace($ReviewSignal)) {
        return [pscustomobject]@{ Score = 0.0; Label = "" }
    }

    $review = $ReviewSignal.ToLowerInvariant()
    $score = 0.0

    if ($review -match "overwhelmingly positive") { $score = 2.0 }
    elseif ($review -match "very positive") { $score = 1.5 }
    elseif ($review -match "mostly positive") { $score = 0.75 }
    elseif ($review -match "\bpositive\b") { $score = 1.0 }
    elseif ($review -match "mixed") { $score = -0.5 }
    elseif ($review -match "mostly negative") { $score = -1.5 }
    elseif ($review -match "negative") { $score = -2.0 }

    return [pscustomobject]@{ Score = $score; Label = $ReviewSignal }
}

function Build-HistoryProfile {
    param(
        [object[]]$Completed,
        [object[]]$Dnf,
        [object[]]$No
    )

    $tagWeights = @{}
    $decisions = @{}

    foreach ($row in $Completed) {
        $ratingValue = ConvertTo-Number (Get-Field $row @("Rating", "Score"))
        $weight = 1.0
        if ($null -ne $ratingValue -and $ratingValue -ge 4) {
            $weight = 1.5
        }

        foreach ($token in (Split-Tags @(
            (Get-Field $row @("Genres", "Genre")),
            (Get-Field $row @("Tags", "SteamTags"))
        ))) {
            Add-WeightedToken $tagWeights $token $weight
        }
    }

    foreach ($row in $Dnf) {
        $title = (Get-Field $row @("Title", "Name")).ToLowerInvariant()
        if ($title.Length -gt 0) {
            $decisions[$title] = "DNF"
        }

        foreach ($token in (Split-Tags @(
            (Get-Field $row @("Genres", "Genre")),
            (Get-Field $row @("Tags", "SteamTags"))
        ))) {
            Add-WeightedToken $tagWeights $token -1.5
        }
    }

    foreach ($row in $No) {
        $title = (Get-Field $row @("Title", "Name")).ToLowerInvariant()
        if ($title.Length -gt 0) {
            $decisions[$title] = "No"
        }

        foreach ($token in (Split-Tags @(
            (Get-Field $row @("Genres", "Genre")),
            (Get-Field $row @("Tags", "SteamTags"))
        ))) {
            Add-WeightedToken $tagWeights $token -2.0
        }
    }

    return [pscustomobject]@{
        TagWeights = $tagWeights
        Decisions = $decisions
    }
}

function Get-Confidence {
    param(
        [double]$Score,
        [int]$EvidenceCount,
        [int]$DataPointCount,
        [bool]$ExactPriorDecision
    )

    if ($ExactPriorDecision) {
        return "High"
    }

    if ([Math]::Abs($Score) -ge 8 -and $EvidenceCount -ge 3) {
        return "High"
    }

    if ($EvidenceCount -ge 2 -or $DataPointCount -ge 4) {
        return "Medium"
    }

    return "Low"
}

function Get-Recommendation {
    param(
        [string]$Source,
        [double]$Score,
        [double]$HoursPlayed,
        [bool]$ExactDnf,
        [bool]$ExactNo,
        [string]$CurrentCategory,
        [string]$Text
    )

    if ($ExactNo) {
        return "No"
    }

    if ($ExactDnf) {
        return "DNF"
    }

    if ($Source -eq "dnf") {
        return "DNF"
    }

    if ($Source -eq "no") {
        return "No"
    }

    if ($CurrentCategory -match "^(?i)dnf$") {
        return "DNF"
    }

    if ($CurrentCategory -match "^(?i)no$") {
        return "No"
    }

    if ($Source -eq "wishlist") {
        if ($Score -ge 9) { return "Buy Soon" }
        if ($Score -le -3) { return "No" }
        return "Wishlist Hold"
    }

    if ($HoursPlayed -gt 0 -and $Score -le -6) {
        return "DNF"
    }

    if ($Text -match "bounced|stalled|no pull|did not click|dropped|boring|bored") {
        if ($HoursPlayed -gt 0) {
            return "DNF"
        }
    }

    if ($Score -ge 10) { return "Shortlist" }
    if ($Score -ge 5) { return "Yes: Later" }
    if ($Score -le -6) { return "No" }

    return "Sample"
}

function New-Rationale {
    param(
        [object[]]$PositiveHits,
        [object[]]$NegativeHits,
        [string[]]$HistoryHits,
        [object]$Review,
        [string]$Recommendation,
        [double]$Score
    )

    $parts = New-Object System.Collections.Generic.List[string]

    if ($PositiveHits.Count -gt 0) {
        $signals = @(
            $PositiveHits |
                Sort-Object Weight -Descending |
                Select-Object -First 3 |
                ForEach-Object { "$($_.Signal) (+$($_.Weight))" }
        )
        $parts.Add("Fit: " + ($signals -join ", ") + ".")
    }

    if ($NegativeHits.Count -gt 0) {
        $signals = @(
            $NegativeHits |
                Sort-Object Weight |
                Select-Object -First 3 |
                ForEach-Object { "$($_.Signal) ($($_.Weight))" }
        )
        $parts.Add("Friction: " + ($signals -join ", ") + ".")
    }

    if ($HistoryHits.Count -gt 0) {
        $parts.Add("History: " + (($HistoryHits | Select-Object -First 3) -join ", ") + ".")
    }

    if ($Review.Score -ne 0) {
        $direction = if ($Review.Score -gt 0) { "helps" } else { "hurts" }
        $parts.Add("Reviews: '$($Review.Label)' $direction only as a secondary signal.")
    }

    if ($parts.Count -eq 0) {
        $parts.Add("Insufficient fit evidence; use a bounded sample or hold rather than committing attention.")
    }

    switch ($Recommendation) {
        "Shortlist" { $parts.Add("Competes now because the fit score is strong ($Score).") }
        "Yes: Later" { $parts.Add("Validated, but not urgent enough to displace the active shortlist.") }
        "Sample" { $parts.Add("Uncertainty is still useful; test for pull before promoting or rejecting.") }
        "DNF" { $parts.Add("Treat the prior test or negative pull signal as enough evidence to stop.") }
        "No" { $parts.Add("Does not look competitive for limited attention.") }
        "Wishlist Hold" { $parts.Add("Do not buy until it has a clearer path into owned priority.") }
        "Buy Soon" { $parts.Add("Likely to enter owned priority if purchased.") }
    }

    return ($parts -join " ")
}

function ConvertTo-MarkdownCell {
    param([object]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ""
    }

    return $text.Replace("|", "\|").Replace("`r", " ").Replace("`n", " ").Trim()
}

function Evaluate-Game {
    param(
        [object]$Row,
        [object[]]$Rules,
        [object]$History
    )

    $source = Get-Field $Row @("Source")
    $title = Get-Field $Row @("Title", "Name", "Game")
    $currentCategory = Get-Field $Row @("CurrentCategory", "Category", "SteamCategory")
    $genres = Get-Field $Row @("Genres", "Genre")
    $tags = Get-Field $Row @("Tags", "SteamTags")
    $series = Get-Field $Row @("Series", "Franchise")
    $notes = Get-Field $Row @("Notes", "Comment", "Comments")
    $reason = Get-Field $Row @("Reason", "RejectionReason")
    $reviewSignal = Get-Field $Row @("ReviewSignal", "Reviews", "SteamReview")
    $priorUnfinished = ConvertTo-BooleanSignal (Get-Field $Row @("PriorEntriesUnfinished", "PriorUnfinished", "SeriesDebt"))
    $hoursPlayed = ConvertTo-Number (Get-Field $Row @("HoursPlayed", "PlaytimeHours", "Hours"))
    if ($null -eq $hoursPlayed) { $hoursPlayed = 0.0 }
    $estimatedHours = ConvertTo-Number (Get-Field $Row @("EstimatedHours", "HowLongToBeat", "Length"))

    $text = @($title, $currentCategory, $genres, $tags, $series, $notes, $reason) -join " "
    $textLower = $text.ToLowerInvariant()
    $score = 0.0
    $positiveHits = New-Object System.Collections.Generic.List[object]
    $negativeHits = New-Object System.Collections.Generic.List[object]

    foreach ($rule in $Rules) {
        $matchedKeyword = $null
        foreach ($keyword in $rule.Keywords) {
            if ($textLower.Contains($keyword)) {
                $matchedKeyword = $keyword
                break
            }
        }

        if ($null -ne $matchedKeyword) {
            $score += $rule.Weight
            $hit = [pscustomobject]@{
                Signal = $rule.Signal
                Weight = $rule.Weight
                Keyword = $matchedKeyword
            }

            if ($rule.Weight -gt 0) {
                $positiveHits.Add($hit)
            }
            else {
                $negativeHits.Add($hit)
            }
        }
    }

    if ($priorUnfinished) {
        $score -= 5
        $negativeHits.Add([pscustomobject]@{ Signal = "prior unfinished entry"; Weight = -5; Keyword = "PriorEntriesUnfinished" })
    }

    if ($null -ne $estimatedHours -and $estimatedHours -ge 40) {
        $score -= 2
        $negativeHits.Add([pscustomobject]@{ Signal = "long estimated runtime"; Weight = -2; Keyword = "$estimatedHours hours" })
    }

    $historyHits = New-Object System.Collections.Generic.List[string]
    foreach ($token in (Split-Tags @($genres, $tags))) {
        if ($History.TagWeights.ContainsKey($token)) {
            $weight = [double]$History.TagWeights[$token]
            $applied = [Math]::Max(-3.0, [Math]::Min(3.0, $weight))
            $score += $applied
            if ($applied -gt 0) {
                $historyHits.Add("shares '$token' with completed games (+$applied)")
            }
            elseif ($applied -lt 0) {
                $historyHits.Add("shares '$token' with rejected games ($applied)")
            }
        }
    }

    $review = Get-ReviewScore $reviewSignal
    $score += $review.Score

    $normalizedTitle = $title.ToLowerInvariant()
    $exactPriorDecision = $History.Decisions.ContainsKey($normalizedTitle)
    $exactDnf = $exactPriorDecision -and $History.Decisions[$normalizedTitle] -eq "DNF"
    $exactNo = $exactPriorDecision -and $History.Decisions[$normalizedTitle] -eq "No"

    $dataPointCount = @($genres, $tags, $series, $notes, $reason, $reviewSignal, $currentCategory) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Measure-Object |
        Select-Object -ExpandProperty Count
    $evidenceCount = $positiveHits.Count + $negativeHits.Count + $historyHits.Count
    if ($review.Score -ne 0) { $evidenceCount += 1 }
    if ($priorUnfinished) { $evidenceCount += 1 }
    if ($exactPriorDecision) { $evidenceCount += 2 }

    $recommendation = Get-Recommendation `
        -Source $source `
        -Score $score `
        -HoursPlayed $hoursPlayed `
        -ExactDnf $exactDnf `
        -ExactNo $exactNo `
        -CurrentCategory $currentCategory `
        -Text $textLower

    $confidence = Get-Confidence `
        -Score $score `
        -EvidenceCount $evidenceCount `
        -DataPointCount $dataPointCount `
        -ExactPriorDecision $exactPriorDecision

    $rationale = New-Rationale `
        -PositiveHits $positiveHits.ToArray() `
        -NegativeHits $negativeHits.ToArray() `
        -HistoryHits $historyHits.ToArray() `
        -Review $review `
        -Recommendation $recommendation `
        -Score ([Math]::Round($score, 1))

    return [pscustomobject]@{
        Title = $title
        Source = $source
        CurrentCategory = $currentCategory
        Recommendation = $recommendation
        Confidence = $confidence
        Score = [Math]::Round($score, 1)
        Rationale = $rationale
    }
}

$dataRoot = Resolve-ProjectPath $DataPath
$rulesRoot = Resolve-ProjectPath $RulesPath
$outputFile = Resolve-ProjectPath $OutputPath
$outputDirectory = Split-Path -Parent $outputFile

if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$backlog = @(Import-GameCsv (Join-Path $dataRoot "backlog.csv") "backlog")
$unplayed = @(Import-GameCsv (Join-Path $dataRoot "unplayed.csv") "unplayed")
$wishlist = @(Import-GameCsv (Join-Path $dataRoot "wishlist.csv") "wishlist")
$completed = @(Import-GameCsv (Join-Path $dataRoot "completed.csv") "completed")
$dnf = @(Import-GameCsv (Join-Path $dataRoot "dnf.csv") "dnf")
$no = @(Import-GameCsv (Join-Path $dataRoot "no.csv") "no")

$rules = @(Read-MarkdownRules $rulesRoot)
$history = Build-HistoryProfile -Completed $completed -Dnf $dnf -No $no
$evaluationRows = @($backlog + $unplayed + $wishlist + $dnf + $no)
$evaluations = @(
    foreach ($row in $evaluationRows) {
        $title = Get-Field $row @("Title", "Name", "Game")
        if (-not [string]::IsNullOrWhiteSpace($title)) {
            Evaluate-Game -Row $row -Rules $rules -History $history
        }
    }
)

$now = Get-Date -Format "yyyy-MM-dd HH:mm"
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Steam Backlog Recommendations")
$lines.Add("")
$lines.Add("Generated: $now")
$lines.Add("")
$lines.Add("This report applies personal taste rules first, uses completed/DNF/No history as local evidence, and treats review sentiment as a secondary tie-breaker.")
$lines.Add("")

if ($evaluations.Count -eq 0) {
    $lines.Add("No games were found in `data/backlog.csv`, `data/unplayed.csv`, `data/wishlist.csv`, `data/dnf.csv`, or `data/no.csv`.")
    $lines.Add("")
    $lines.Add("Add rows to the CSV files, then rerun `.\scripts\Invoke-BacklogCuration.ps1`.")
}
else {
    $lines.Add("## Summary")
    $lines.Add("")
    $summary = $evaluations | Group-Object Recommendation | Sort-Object Name
    foreach ($group in $summary) {
        $lines.Add("- $($group.Name): $($group.Count)")
    }
    $lines.Add("")

    $categoryOrder = @("Shortlist", "Buy Soon", "Yes: Later", "Sample", "Wishlist Hold", "DNF", "No")
    foreach ($category in $categoryOrder) {
        $items = @($evaluations | Where-Object { $_.Recommendation -eq $category } | Sort-Object @{ Expression = "Score"; Descending = $true }, Title)
        if ($items.Count -eq 0) {
            continue
        }

        $lines.Add("## $category")
        $lines.Add("")
        $lines.Add("| Game | Source | Current | Confidence | Score | Why |")
        $lines.Add("| --- | --- | --- | --- | ---: | --- |")
        foreach ($item in $items) {
            $lines.Add("| $(ConvertTo-MarkdownCell $item.Title) | $(ConvertTo-MarkdownCell $item.Source) | $(ConvertTo-MarkdownCell $item.CurrentCategory) | $(ConvertTo-MarkdownCell $item.Confidence) | $($item.Score) | $(ConvertTo-MarkdownCell $item.Rationale) |")
        }
        $lines.Add("")
    }
}

$lines.Add("## Rule Inputs")
$lines.Add("")
$lines.Add("- Parsed rules: $($rules.Count)")
$lines.Add("- Backlog rows: $($backlog.Count)")
$lines.Add("- Computed unplayed rows: $($unplayed.Count)")
$lines.Add("- Wishlist rows: $($wishlist.Count)")
$lines.Add("- Completed evidence rows: $($completed.Count)")
$lines.Add("- DNF evidence rows: $($dnf.Count)")
$lines.Add("- No evidence rows: $($no.Count)")
$lines.Add("")
$lines.Add("Tune `rules/taste-profile.md` and `rules/friction-rules.md` when recommendations feel directionally wrong.")

Set-Content -LiteralPath $outputFile -Value $lines -Encoding UTF8
Write-Host "Wrote $outputFile"
