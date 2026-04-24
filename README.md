# Steam Backlog Curator

A CSV-driven backlog curation tool that applies your taste profile before generic review sentiment.

## Quick Start

1. Fill or generate the CSV files in `data/`.
2. Adjust the markdown rule tables in `rules/`.
3. Run:

```powershell
.\scripts\Invoke-BacklogCuration.ps1
```

4. Read `outputs/recommendations.md`.

Generated `data/*.csv` files and `outputs/*.md` reports are ignored by git because they can contain personal library data. Commit the `data/*.example.csv` files as schema examples, not your generated library exports.

## Local Steam Sync

The local sync path is:

```powershell
.\scripts\Import-SteamCollections.ps1
.\scripts\Import-SteamAppInfo.ps1
.\scripts\Sync-SteamCategories.ps1
.\scripts\Invoke-BacklogCuration.ps1
```

This keeps category ingestion local. Steam collection membership comes from your Steam userdata files, and game titles come from Steam's local `appcache\appinfo.vdf`.

Requirements:

- PowerShell 7 or Windows PowerShell.
- .NET SDK 10 for `tools/SteamMetadataReader`.
- Local read access to your Steam install and userdata.

## Codex Skill

This repo includes a shareable Codex skill at:

```text
skills/backlog-curator
```

The skill teaches Codex how to locate or clone this repo, run the local Steam import/sync/report workflow, preserve private CSV data, and help discuss backlog decisions. It does not contain your Steam library data.

Install it for your local Codex setup:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.codex\skills" | Out-Null
Copy-Item -Recurse -Force .\skills\backlog-curator "$env:USERPROFILE\.codex\skills\backlog-curator"
```

On macOS/Linux:

```bash
mkdir -p ~/.codex/skills
cp -R ./skills/backlog-curator ~/.codex/skills/backlog-curator
```

Then use prompts like:

```text
Use the backlog-curator skill to run the local Steam sync and summarize what changed.
```

```text
Use the backlog-curator skill to review my Sample recommendations.
```

The sync script maps Steam collections through:

```text
rules/category-map.csv
```

By default:

```text
ShortList      -> unplayed.csv, CurrentCategory=Shortlist
Yes: Later     -> unplayed.csv, CurrentCategory=Yes: Later
Credits Rolled -> completed.csv
DNF            -> dnf.csv
No             -> no.csv
```

Rows are merged by `AppId`. User-maintained fields such as `Notes`, `Reason`, `Rating`, `ReviewSignal`, `Genres`, and `Tags` are preserved when possible.

## Import Steam Collections

The tool can read your local Steam client files and export manual Steam Library collections to:

```text
data/steam_collections.csv
```

Run:

```powershell
.\scripts\Import-SteamCollections.ps1
```

Optional arguments:

```powershell
.\scripts\Import-SteamCollections.ps1 -SteamPath "C:\Program Files (x86)\Steam" -AccountId 12345678
```

The importer is read-only against Steam. It scans Steam userdata and writes a normalized CSV with:

```csv
AccountId,AppId,Collections,Source
```

### What It Needs

- A local Steam client install.
- Read access to the Steam install directory.
- Read access to your Steam userdata folder.
- Write access to this repo's `data/` directory.
- Steam collections that have been created manually in the Steam client.

On Windows, the main files checked are:

```text
C:\Program Files (x86)\Steam\userdata\<account_id>\config\cloudstorage\cloud-storage-namespace-1.json
C:\Program Files (x86)\Steam\userdata\<account_id>\config\localconfig.vdf
C:\Program Files (x86)\Steam\userdata\<account_id>\7\remote\sharedconfig.vdf
```

If Steam is open, some files may still be mid-session or locked. Exit Steam first if the importer does not find expected collections.

### Manual Categories Only

This importer supports manual Steam Library collections/categories only.

It does not currently import:

- Dynamic collections generated from Steam tags or store metadata.
- Smart collections that are not materialized as explicit app IDs.
- Wishlist categories.
- Completion status inferred from achievements.
- Private Steam account data from another user's machine.

That limitation is intentional. Manual categories are the useful signal for backlog curation because they represent your own decisions, not Steam's generic metadata.

## Import Steam App Metadata

The app metadata importer reads Steam's local app metadata cache:

```text
C:\Program Files (x86)\Steam\appcache\appinfo.vdf
```

Run:

```powershell
.\scripts\Import-SteamAppInfo.ps1
```

It writes:

```text
data/steam_apps.csv
```

with:

```csv
AppId,Title,Type,Developer,Publisher,Franchise,LastUpdated,ChangeNumber
```

This does not prove ownership by itself. `appinfo.vdf` is a metadata cache, so the sync script uses it to name and enrich games discovered from Steam collections.

### Unplayed Policy

Steam's built-in `Unplayed` collection is dynamic, so the curator should compute it rather than treat it as a normal manual category.

The intended rule is:

```text
Unplayed = owned games with zero playtime
  - games in No
  - Steam's explicit Unplayed removed overrides
  + Steam's explicit Unplayed added overrides
```

`No` always wins over `Unplayed`. A zero-playtime game in `No` should stay out of `unplayed.csv` because it no longer competes for limited attention.

## CSV Fields

The evaluator looks for these columns when present:

- `Title`
- `AppId`
- `CurrentCategory`
- `Genres`
- `Tags`
- `Series`
- `PriorEntriesUnfinished`
- `HoursPlayed`
- `EstimatedHours`
- `ReviewSignal`
- `Notes`
- `Reason`
- `Rating`
- `StoreUrl`
- `Price`

You can leave fields blank. More notes and tags usually produce better rationale.

## Rule Format

Rules are read from markdown tables in `rules/taste-profile.md` and `rules/friction-rules.md`.

The script recognizes rows shaped like:

```markdown
| Signal | Weight | Keywords | Why |
| tight combat | 5 | tight combat, responsive, melee | Combat feel can create immediate pull. |
```

Positive weights increase fit. Negative weights add friction. Keywords are comma-separated.
