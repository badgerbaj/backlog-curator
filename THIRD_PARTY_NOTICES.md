# Third-Party Notices

## SteamAppInfo

The local Steam app metadata reader follows the documented file-layout approach from ValveResourceFormat/SteamAppInfo.

- Repository: https://github.com/ValveResourceFormat/SteamAppInfo
- License: MIT
- Copyright: Copyright (c) 2020 SteamDB

## ValveKeyValue

The Steam metadata reader uses ValveResourceFormat/ValveKeyValue to deserialize Valve KeyValues data.

- Repository: https://github.com/ValveResourceFormat/ValveKeyValue
- NuGet: https://www.nuget.org/packages/ValveKeyValue
- License: MIT

## HowLongToBeat Wrapper References

`Update-GameMetadata.ps1` does not ship a runtime dependency on a third-party HowLongToBeat package, but its request/response handling was informed by public wrapper projects and public examples describing the HLTB search API shape.

- Reference repository: https://github.com/ckatzorke/howlongtobeat
- Reference repository: https://github.com/RedSkiesReaperr/howlongtobeat
