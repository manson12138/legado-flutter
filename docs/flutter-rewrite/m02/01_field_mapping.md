# M02 Field Mapping

Last updated: 2026-07-13

事实来源：Android `app/src/main/java/io/legado/app/data/entities/`、对应 `data/dao/`、
`app/schemas/io.legado.app.data.AppDatabase/94.json`，以及书源导入、加入书架、目录读取和阅读进度真实调用点。
以下 Dart 模型位于 `flutter_app/lib/src/domain/model/`，保持纯 Dart，不依赖 sqflite。

## Book / books

| Android/DB field | Dart type | Null/default | Key/index and meaning |
|---|---|---|---|
| `bookUrl` | `String` | non-null, `''` only for Android schema compatibility; UseCase rejects empty | PK; detail URL/local full path, never normalized |
| `tocUrl` | `String` | `''` | TOC URL; empty means unresolved |
| `origin` | `String` | `'loc_book'` | source URL/local tag |
| `originName` | `String` | `''` | source name/local filename |
| `name`, `author` | `String` | `''` | composite non-unique index; book identity fallback calls use both |
| `kind`, `customTag` | `String?` | `null` | source tag vs user tag |
| `coverUrl`, `customCoverUrl` | `String?` | `null` | source cover vs user override |
| `intro`, `customIntro` | `String?` | `null` | source intro vs user override |
| `remark`, `charset` | `String?` | `null` | user remark/local charset |
| `type` | `int` | `0` | Android `BookType` bit mask |
| `group` | `int` | `0` | user group bit mask; 0 is meaningful no-group |
| `latestChapterTitle` | `String?` | `null` | newest known chapter title |
| `latestChapterTime`, `lastCheckTime` | `int` | `0` | Epoch milliseconds; 0 unknown/not checked |
| `lastCheckCount`, `totalChapterNum` | `int` | `0` | new-count and TOC total |
| `durChapterTitle` | `String?` | `null` | current chapter title |
| `durChapterIndex`, `durChapterPos` | `int` | `0` | zero-based chapter and first visible character |
| `durChapterTime` | `int` | `0` | Epoch milliseconds; indexed for recent reading sort |
| `wordCount` | `String?` | `null` | display text, not coerced to number |
| `canUpdate` | `bool` | `true` | shelf refresh switch |
| `order`, `originOrder` | `int` | `0` | manual order and source order |
| `variable` | `String?` | `null` | rule variable JSON text |
| `readConfig` | `ReadConfig?` | `null` | JSON column; null means no per-book override |
| `syncTime` | `int` | `0` | Epoch milliseconds; 0 never synced |

## BookSource / book_sources

| Field | Dart type | Null/default | Meaning |
|---|---|---|---|
| `bookSourceUrl` | `String` | required | PK and source identity, never normalized |
| `bookSourceName` | `String` | required | display name |
| `bookSourceGroup` | `String?` | `null` | delimited group text |
| `bookSourceType` | `int` | `0` | 0 text, 1 audio, 2 image, 3 file, 4 video |
| `bookUrlPattern` | `String?` | `null` | detail URL regex |
| `customOrder` | `int` | `0` | manual sort |
| `enabled`, `enabledExplore` | `bool` | `true` | search/general and explore switches |
| `jsLib` | `String?` | `null` | shared JavaScript library |
| `enabledCookieJar` | `bool?` | missing import defaults true; explicit null retained | historical nullable cookie switch |
| `concurrentRate` | `String?` | `null` | concurrency rule text |
| `header` | `String?` | `null` | raw string or imported JSON encoded as text |
| `loginUrl`, `loginUi`, `loginCheckJs` | `String?` | `null` | login definitions/check script |
| `coverDecodeJs` | `String?` | `null` | cover decryption script |
| `bookSourceComment`, `variableComment` | `String?` | `null` | comments |
| `lastUpdateTime` | `int` | `0` | Epoch milliseconds |
| `respondTime` | `int` | `180000` | milliseconds |
| `weight` | `int` | `0` | smart-sort weight |
| `exploreUrl`, `exploreScreen`, `searchUrl` | `String?` | `null` | raw URL/rule text |
| `ruleExplore`, `ruleSearch`, `ruleBookInfo`, `ruleToc`, `ruleContent`, `ruleReview` | `String?` | `null` | imported rule objects encoded to JSON text; M3 creates typed rule models |
| `eventListener`, `customButton` | `bool` | `false` | callback/custom-button switches |
| `homepageModules` | `String?` | `null` | module array JSON text |

`BookSourceImportDecoder` is separate from the persistent model. It accepts a single object or array,
supports historical boolean 0/1 and integer strings, retains explicit null, and rejects invalid required fields atomically.

## BookChapter / chapters

| Field | Dart type | Null/default | Key/index and meaning |
|---|---|---|---|
| `url`, `bookUrl` | `String` | required | composite PK; `bookUrl` FK to books with CASCADE |
| `title` | `String` | required | chapter title |
| `isVolume` | `bool` | false | volume heading flag |
| `baseUrl` | `String` | `''` | relative URL base |
| `index` | `int` | required | unique with `bookUrl`, zero-based order |
| `isVip`, `isPay` | `bool` | false | VIP/purchased flags |
| `resourceUrl`, `tag`, `wordCount` | `String?` | null | audio URL/extra tag/display count |
| `start`, `end` | `int?` | null | local file offsets; null when not applicable |
| `startFragmentId`, `endFragmentId` | `String?` | null | EPUB fragment bounds |
| `variable`, `reviewImg` | `String?` | null | rule JSON/review icon |

## BookGroup / book_groups

| Field | Dart type | Null/default | Meaning |
|---|---|---|---|
| `groupId` | `int` | required | PK; positive values are bit masks, negative values are system groups |
| `groupName` | `String` | required | name |
| `cover` | `String?` | null | cover URL/path |
| `order` | `int` | 0 | display order |
| `enableRefresh`, `show` | `bool` | true | refresh/display switches |
| `bookSort` | `int` | -1 | -1 inherits global sort |
| `isPrivate` | `bool` | false | privacy flag |

## SearchBook / searchBooks

| Field | Dart type | Null/default | Meaning |
|---|---|---|---|
| `bookUrl` | `String` | required | PK and unique index |
| `origin` | `String` | required | FK to book source with CASCADE |
| `originName`, `name`, `author` | `String` | required | source/book identity text |
| `type` | `int` | 0 | BookType bit mask |
| `kind`, `coverUrl`, `intro`, `wordCount`, `latestChapterTitle` | `String?` | null | search result metadata |
| `tocUrl` | `String` | `''` | unresolved represented by empty string |
| `time` | `int` | 0 | search cache write time in Epoch milliseconds |
| `variable` | `String?` | null | rule variable JSON |
| `originOrder` | `int` | 0 | source ordering |
| `chapterWordCountText` | `String?` | null | raw display text |
| `chapterWordCount`, `respondTime` | `int` | -1 | -1 means unknown |

`SearchBook.toBook(createdAt:)` is the explicit conversion boundary; search-only timing fields are not silently copied.

## Bookmark / bookmarks

| Field | Dart type | Null/default | Meaning |
|---|---|---|---|
| `time` | `int` | required | PK, creation Epoch milliseconds |
| `bookName`, `bookAuthor` | `String` | required | non-unique composite index and Android-compatible association |
| `chapterIndex`, `chapterPos` | `int` | required | location |
| `chapterName`, `bookText`, `content` | `String` | required | title/context/user content |

## Cookie / cookies

| Field | Dart type | Null/default | Meaning |
|---|---|---|---|
| `url` | `String` | required | PK/unique index; historical `|` composite keys retained |
| `cookie` | `String` | required | sensitive raw Cookie text, never logged |

## Cache / caches

| Field | Dart type | Null/default | Meaning |
|---|---|---|---|
| `key` | `String` | required | PK/unique index |
| `value` | `String?` | null | explicit null differs from empty value |
| `deadline` | `int` | 0 | Epoch milliseconds; 0 never expires |

## ReplaceRule / replace_rules

| Field | Dart type | Null/default | Meaning |
|---|---|---|---|
| `id` | `int?` | null before insert | SQLite AUTOINCREMENT PK |
| `name`, `pattern`, `replacement` | `String` | `''` | rule identity/match/replacement |
| `group`, `scope`, `excludeScope` | `String?` | null | grouping and include/exclude scope |
| `scopeTitle` | `bool` | false | title switch |
| `scopeContent` | `bool` | true | content switch |
| `isEnabled`, `isRegex` | `bool` | true | enable/regex switches |
| `timeoutMillisecond` | `int` | 3000 | regex timeout in milliseconds |
| `order` / DB `sortOrder` | `int` | 0 | manual order and preserved column alias |

## ReadConfig core configuration

All fields correspond to Android `Book.ReadConfig`: `reverseToc`, nullable `pageAnim`, `reSegment`,
nullable `imageStyle`, nullable `useReplaceRule`, `delTag`, nullable `ttsEngine`, `splitLongChapter`,
`readSimulating`, nullable ISO date `startDate`, nullable `startChapter`, `dailyChapters`, nullable
`mangaColorFilter`, nullable `mangaScrollMode`, nullable `webtoonSidePaddingDp`, nullable
`mangaBackground`, `fixedType`, and `translationMode`. Explicit null is retained for settings that inherit a global value.

