[CmdletBinding()]
param(
    [string]$SteamPath,
    [string]$AccountId,
    [string]$OutputPath = (Join-Path $PSScriptRoot "..\data\steam_collections.csv")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-OutputPath {
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

function Get-SteamAccounts {
    param([string]$Root)

    $userdata = Join-Path $Root "userdata"
    if (-not (Test-Path -LiteralPath $userdata)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $userdata -Directory | Where-Object { $_.Name -match "^\d+$" -and $_.Name -ne "0" })
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

function ConvertTo-CollectionRows {
    param(
        [string]$AccountId,
        [string]$Source,
        [hashtable]$AppCollections
    )

    foreach ($appId in ($AppCollections.Keys | Sort-Object { [int64]$_ })) {
        $collections = @($AppCollections[$appId] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($collections.Count -eq 0) {
            continue
        }

        [pscustomobject]@{
            AccountId = $AccountId
            AppId = $appId
            Collections = ($collections -join "; ")
            Source = $Source
        }
    }
}

function Get-SharedConfigCollections {
    param(
        [string]$Path,
        [string]$AccountId
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $vdf = ConvertFrom-SimpleVdf -Path $Path
    $apps = Get-NestedValue $vdf @("UserRoamingConfigStore", "Software", "Valve", "Steam", "apps")
    if ($null -eq $apps) {
        return @()
    }

    $appCollections = @{}
    foreach ($appId in $apps.Keys) {
        $app = $apps[$appId]
        if (-not ($app -is [System.Collections.IDictionary]) -or -not $app.Contains("tags")) {
            continue
        }

        $tags = $app["tags"]
        if (-not ($tags -is [System.Collections.IDictionary])) {
            continue
        }

        $appCollections[$appId] = @($tags.Values)
    }

    return @(ConvertTo-CollectionRows -AccountId $AccountId -Source "sharedconfig.vdf" -AppCollections $appCollections)
}

function Get-LocalConfigCollections {
    param(
        [string]$Path,
        [string]$AccountId
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $vdf = ConvertFrom-SimpleVdf -Path $Path
    $store = Get-NestedValue $vdf @("UserLocalConfigStore", "Software", "Valve", "Steam")
    if ($null -eq $store -or -not $store.Contains("user-collections")) {
        return @()
    }

    $json = [string]$store["user-collections"]
    if ([string]::IsNullOrWhiteSpace($json) -or $json.Trim() -eq "{}") {
        return @()
    }

    $parsed = $json | ConvertFrom-Json
    $appCollections = @{}

    foreach ($property in $parsed.PSObject.Properties) {
        $collectionName = $property.Name
        $value = $property.Value

        $appIds = @()
        if ($value.PSObject.Properties["appids"]) {
            $appIds = @($value.appids)
        }
        elseif ($value.PSObject.Properties["rgAppIDs"]) {
            $appIds = @($value.rgAppIDs)
        }
        elseif ($value -is [array]) {
            $appIds = @($value)
        }

        foreach ($appId in $appIds) {
            $key = [string]$appId
            if (-not $appCollections.ContainsKey($key)) {
                $appCollections[$key] = @()
            }
            $appCollections[$key] += $collectionName
        }
    }

    return @(ConvertTo-CollectionRows -AccountId $AccountId -Source "localconfig.vdf:user-collections" -AppCollections $appCollections)
}

function Get-CloudStorageCollections {
    param(
        [string]$Path,
        [string]$AccountId
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $entries = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    $appCollections = @{}

    foreach ($entry in $entries) {
        if ($entry.Count -lt 2) {
            continue
        }

        $key = [string]$entry[0]
        $record = $entry[1]
        if ($key -notlike "user-collections.*") {
            continue
        }

        if ($record.PSObject.Properties["is_deleted"] -and $record.is_deleted) {
            continue
        }

        if (-not $record.PSObject.Properties["value"]) {
            continue
        }

        $collection = $record.value | ConvertFrom-Json
        $collectionName = [string]$collection.name
        if ([string]::IsNullOrWhiteSpace($collectionName)) {
            continue
        }

        $added = @()
        if ($collection.PSObject.Properties["added"]) {
            $added = @($collection.added)
        }

        $removed = @()
        if ($collection.PSObject.Properties["removed"]) {
            $removed = @($collection.removed | ForEach-Object { [string]$_ })
        }

        foreach ($appId in $added) {
            $appIdText = [string]$appId
            if ([string]::IsNullOrWhiteSpace($appIdText) -or $removed -contains $appIdText) {
                continue
            }

            if (-not $appCollections.ContainsKey($appIdText)) {
                $appCollections[$appIdText] = @()
            }
            $appCollections[$appIdText] += $collectionName
        }
    }

    return @(ConvertTo-CollectionRows -AccountId $AccountId -Source "cloudstorage:user-collections" -AppCollections $appCollections)
}

$steamRoot = Get-SteamPath -ExplicitPath $SteamPath
$accounts = @(Get-SteamAccounts -Root $steamRoot)
if ($AccountId) {
    $accounts = @($accounts | Where-Object { $_.Name -eq $AccountId })
    if ($accounts.Count -eq 0) {
        throw "AccountId '$AccountId' was not found under $steamRoot\userdata."
    }
}

$rows = @()
foreach ($account in $accounts) {
    $sharedConfig = Join-Path $account.FullName "7\remote\sharedconfig.vdf"
    $localConfig = Join-Path $account.FullName "config\localconfig.vdf"
    $cloudStorage = Join-Path $account.FullName "config\cloudstorage\cloud-storage-namespace-1.json"

    $rows += Get-SharedConfigCollections -Path $sharedConfig -AccountId $account.Name
    $rows += Get-LocalConfigCollections -Path $localConfig -AccountId $account.Name
    $rows += Get-CloudStorageCollections -Path $cloudStorage -AccountId $account.Name
}

$rows = @(
    $rows |
        Sort-Object AccountId, AppId, Source |
        Group-Object AccountId, AppId |
        ForEach-Object {
            $collections = @($_.Group.Collections -split ";\s*" | Where-Object { $_ } | Select-Object -Unique)
            [pscustomobject]@{
                AccountId = $_.Group[0].AccountId
                AppId = $_.Group[0].AppId
                Collections = ($collections -join "; ")
                Source = ($_.Group.Source | Select-Object -Unique) -join "; "
            }
        }
)

$outputFile = Resolve-OutputPath $OutputPath
$outputDirectory = Split-Path -Parent $outputFile
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

if ($rows.Count -eq 0) {
    Set-Content -LiteralPath $outputFile -Value '"AccountId","AppId","Collections","Source"' -Encoding UTF8
}
else {
    $rows | Export-Csv -LiteralPath $outputFile -NoTypeInformation -Encoding UTF8
}
Write-Host "Steam path: $steamRoot"
Write-Host "Accounts scanned: $($accounts.Count)"
Write-Host "Collection rows written: $($rows.Count)"
Write-Host "Output: $outputFile"
