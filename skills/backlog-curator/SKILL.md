---
name: backlog-curator
description: Operate or set up a Steam backlog-curation workflow using the backlog-curator repo. Use when the user wants to import Steam Library collections, parse local Steam metadata, sync CSV backlog categories, generate recommendation reports, discuss Shortlist/Yes Later/Sample/DNF/No decisions, tune taste rules, or clone/scaffold the public backlog-curator tool in a workspace.
---

# Backlog Curator

Use this skill to help a user run and reason about the `backlog-curator` project. The skill is repo-aware: it does not contain user data, but it can locate, create, clone, or operate a project checkout that contains the scripts, rules, and CSVs.

## Locate The Project

First find a directory containing most of:

- `scripts/Import-SteamCollections.ps1`
- `scripts/Import-SteamAppInfo.ps1`
- `scripts/Sync-SteamCategories.ps1`
- `scripts/Invoke-BacklogCuration.ps1`
- `rules/taste-profile.md`
- `rules/category-map.csv`

Prefer the current working directory, then parent directories, then likely code roots. If the project is not present, ask for the desired location or offer to clone/scaffold it. Do not assume the user's personal generated CSVs are committed; `data/*.csv` may be git-ignored.

## First-Run Workflow

From the project root, use PowerShell:

```powershell
pwsh ./scripts/Import-SteamCollections.ps1
pwsh ./scripts/Import-SteamAppInfo.ps1
pwsh ./scripts/Sync-SteamCategories.ps1
pwsh ./scripts/Invoke-BacklogCuration.ps1
```

On Windows PowerShell, `.\scripts\...` is also fine.

Expected dependencies:

- PowerShell or PowerShell 7.
- .NET SDK 10 for `tools/SteamMetadataReader`.
- Local read access to Steam install/userdata for local import.

If `dotnet restore` is needed and network is sandboxed, request approval. Keep `DOTNET_CLI_HOME`, `NUGET_PACKAGES`, and `APPDATA` pointed inside the repo if the normal user profile paths are blocked.

## Data Privacy

Treat generated files as private by default:

- `data/*.csv`
- `outputs/*.md`

Do not commit or print large personal library exports unless the user asks. Prefer summaries, counts, category names, and selected rows relevant to the discussion.

## Category Semantics

Use the user's attention model:

- `Shortlist`: active finish candidate.
- `Yes: Later`: validated future interest.
- `Sample`: uncertainty worth testing.
- `DNF`: tested and rejected.
- `No`: not competitive for limited attention.
- `Wishlist Hold`: unowned; wait for stronger evidence.
- `Buy Soon`: unowned; likely to become priority.

`No` wins over computed `Unplayed`. A zero-playtime game in `No` should stay out of the attention pool.

Steam collection aliases live in `rules/category-map.csv`. Update that map rather than hard-coding new category names in scripts when possible.

## Curation Workflow

1. Read `README.md`, `AGENTS.md`, and `rules/`.
2. Check whether `data/steam_collections.csv`, `data/steam_apps.csv`, and `outputs/recommendations.md` exist.
3. If data is stale or missing, offer to run the local sync workflow.
4. Review one slice at a time: `Shortlist`, `Sample`, `Yes: Later`, `DNF`, or `No`.
5. Prioritize personal taste rules over generic review sentiment.
6. Preserve hand-authored fields such as `Notes`, `Reason`, `Rating`, `ReviewSignal`, `Genres`, and `Tags`.
7. When confidence is low, recommend a bounded sample rather than overclaiming.

## Editing Guidance

When updating project data:

- Merge by `AppId` when available.
- Do not erase notes or reasons unless the user explicitly asks.
- Prefer adding rationale to `Notes`/`Reason` over silently changing categories.
- If recommendations feel wrong, tune `rules/taste-profile.md`, `rules/friction-rules.md`, or `rules/category-map.csv` before changing evaluator code.

Useful prompts to support:

- "Run the local Steam sync and summarize what changed."
- "Review my Sample recommendations and suggest promotions/rejections."
- "Help tune my taste rules based on these wrong recommendations."
- "Explain why this game is not competing for attention."
- "Prepare a public-safe commit that excludes generated library data."

