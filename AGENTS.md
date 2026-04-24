# Backlog Curator Agent Notes

This project curates a Steam backlog from CSV files and local preference rules.

## Operating Principles

- Personal taste rules are the primary source of truth.
- Review sentiment is secondary and should only break close calls.
- The goal is clarity, not completion count.
- Flag uncertainty explicitly instead of pretending to know.
- Every recommendation needs a short rationale.

## Inputs

- `data/unplayed.csv`: owned games that need evaluation.
- `data/wishlist.csv`: unowned wishlist games.
- `data/completed.csv`: positive and negative evidence from finished games.
- `data/dnf.csv`: tested games rejected by experience.
- `data/no.csv`: games already ruled out.

## Outputs

- `outputs/recommendations.md`: generated category recommendations and rationale.

## Commands

Run the local Steam import and sync from the project root:

```powershell
.\scripts\Import-SteamCollections.ps1
.\scripts\Import-SteamAppInfo.ps1
.\scripts\Sync-SteamCategories.ps1
```

Run the curator report:

```powershell
.\scripts\Invoke-BacklogCuration.ps1
```

Optional explicit paths:

```powershell
.\scripts\Invoke-BacklogCuration.ps1 -DataPath .\data -RulesPath .\rules -OutputPath .\outputs\recommendations.md
```
