# Official Firestorm news

The news protocol was recovered by static inspection of the supplied **Firestorm Launcher 2.0.37** Windows installer. The installer and its executables were not run. The NSIS payload was extracted and the embedded Tauri JavaScript assets were decompressed from Brotli; the Rust request construction was checked in the executable.

Installer SHA-256:

```text
a757261325dad287059ed599384837e0577c6278c21d7fc9c18c9097fb0caac8
```

## Request

```http
POST https://api.firestorm-servers.com/cgi-bin/processACT
Content-Type: application/json
User-Agent: Firestorm/2.0
```

```json
{
  "jsonrpc": "2.0",
  "method": "GetLauncherLastNews",
  "params": ["APPLICATION_IDENTIFIER", 30, 0, ""],
  "id": 1
}
```

Parameter order matters. The generic Rust API client **prepends** its application-wide identifier to the method arguments. The identifier is a constant distributed in the original installer, not an account token or a user's password. Shared request construction and the identifier are implemented in `Sources/FirestormAPI.swift`.

The remaining arguments are the maximum item count, numeric language ID, and an optional subcategory ID encoded as a string. The generic endpoint `/` and an empty application identifier are not equivalent requests and return errors.

| Interface language | RPC locale ID |
| --- | --- |
| English | 0 |
| French | 1 |
| Spanish | 3 |
| Russian | 4 |
| Portuguese | 7 |

## Response

Success is a JSON-RPC envelope with `result.ErrorID == 0` and `result.News` containing an array. HTTP 200 alone does not indicate API success. Both top-level `error` and nonzero `result.ErrorID` must be checked.

| Field | Meaning |
| --- | --- |
| `ID` | Article ID; may be a decimal string |
| `Date` | Unix seconds; may be a decimal string |
| `CategoryID` | Homepage news uses category 1 |
| `Visible` | Publication visibility |
| `HideFromHomepage` | Excludes an item from the homepage |
| `Picture` | Preferred image filename |
| `PictureAlt` | Alternative image filename |
| `Title` | Translations indexed by locale |
| `Content` | Translated article HTML |

Translations are objects or arrays of `{ "Locale": 0, "Value": "text" }`. A response includes all translations even when a particular locale was requested. Select the requested translation, then English, then the first nonempty available translation.

Article URLs use `https://firestorm-servers.com/{en|ru}/news/{ID}`. Images use `https://firestorm-servers.com/assets/img/news/{filename}`. Filenames must not be accepted as arbitrary URLs or filesystem paths.

The original homepage requests 30 items and retains category 1 entries that are not hidden. Its news query has a 30-minute freshness period. The original application also has reserved-news methods; reserved/pinned articles are not necessarily present in `GetLauncherLastNews`. This launcher displays the latest-news feed, not a copy of the original reserved-news carousel.

## macOS behavior

- Native cards show three articles, with localized dates and thumbnails.
- The in-memory response cache can supply either interface language without downloading the same multilingual payload again.
- Refresh invalidates the cache. Visible windows refresh automatically every 30 minutes.
- Requests are asynchronous, time-limited, and separate from game preparation, downloads and login.
- API responses are capped at 8 MiB. Thumbnail transfers are capped at 4 MiB and decoded at reduced resolution off the main thread.
- News requests use an ephemeral session without account cookies or credential storage. TLS certificate validation is unchanged.
- HTML is converted to native text using Foundation with external entities disabled. Fixes retain validated Wowhead links as attributed-text ranges; article scripts never execute in the launcher. Full articles and Wowhead references open in the default browser.
- Feed errors leave installation and Play available, and the website link remains usable.

The endpoint and a valid anonymous application context were verified against live English and Russian responses. Parser tests use short synthetic records rather than distributing article bodies or the Windows executable.

## Latest Midnight fixes

The live Midnight game configuration uses fixes subcategory **34**. Its public request is the same `GetLauncherLastNews` RPC, with parameters `[APPLICATION_IDENTIFIER, count, localeID, "34"]`. The official launcher requests 50 records; this launcher requests five because its panel displays the latest available entry.

Fixes are category **2**, with `Visible == 1`. Their `HideFromHomepage == 1` value is intentional: applying the ordinary category-1 news filter would discard all fixes. `Title` and `Content` use the same localized records as news. The latest note is kept in full, including paragraphs, headings and nested lists, rather than being shortened to the news summary length.

The full changelog link is `https://firestorm-servers.com/{locale}/news/dev`; individual note links retain the usual `/news/{ID}` format. The original fixes query has a five-minute freshness period. The reserved-fixes API is a beta fallback and is not needed for the live Midnight feed. Source bold emphasis and section headings are preserved as native font attributes, including class names inside lists.

Wowhead anchors retain their original labels and URLs, including the Russian `/ru/` paths. The native renderer tracks UTF-16 link ranges while inserting list markers, indentation and paragraph breaks, so repeated names and non-ASCII text keep the correct destinations. Only HTTPS URLs on `wowhead.com` or its subdomains are made clickable; ordinary HTTP Wowhead links are upgraded to HTTPS. Scripts, unsupported schemes, credentials and unrelated hosts remain non-clickable text.

## Silvermoon realm population

```json
{
  "jsonrpc": "2.0",
  "method": "GetAllRealmsInfo",
  "params": ["APPLICATION_IDENTIFIER"],
  "id": 1
}
```

Read `result.Realms` and select **ID 14**, Silvermoon. Do not use `GetTotalOnlinePlayerCount`, which counts players across all realms.

| Field | Meaning |
| --- | --- |
| `ID` | Realm ID; Silvermoon is 14 |
| `Name` | Realm name |
| `Online` | Player count, not an availability flag |
| `Lastupdate` | Last realm heartbeat, in Unix seconds |
| `AllowedSecurityLevel` | Nonzero means access is restricted |

The original availability rule is `Lastupdate + 150 >= current Unix time`. A fresh heartbeat with zero players still means online; an old heartbeat with a positive stored player count means offline. Missing or invalid heartbeat data is an unavailable-status error rather than an invented offline or zero-player result.

Realm responses have a 30-second in-memory freshness period and a 120-second visible-window polling interval. Manual refresh invalidates the cache. Failed requests are shown separately, and any retained player count is explicitly labeled as last known. This realm status is independent of the existing TCP reachability indicator for the login endpoint.

The fixes and realm APIs were verified anonymously against the same official endpoint. Neither feature sends player credentials, changes certificate validation, or affects game preparation and launching.
