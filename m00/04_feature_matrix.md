# M00 Feature Matrix

Last updated: 2026-07-14

## First-Wave Features

| Feature | Android Entry | Core Android Files | Flutter Target | Acceptance Signal | Owner | Status | Updated |
|---|---|---|---|---|---|---|---|
| App shell | `MainActivity`, `MainNavGraph` | `ui/main/**` | `app_shell`, router, theme, DI | App starts and shows main framework. | Codex | NOT_STARTED | 2026-07-13 |
| Book source import | `ImportBookSourceDialog`, `QrCodeActivity`, online/file associations | `ui/association/**`, `data/entities/BookSource.kt` | Source import flow | File/text/clipboard and Android/iOS camera QR JSON/URL import plus conflict summary implemented; user execution pending. | Codex + user | IN_PROGRESS | 2026-07-14 |
| Book source management | `BookSourceActivity` | `ui/book/source/manage/**`, `BookSourceDao` | Source list/manage screens | Enable/disable/group/edit/delete basics implemented; user execution pending. | Codex + user | IN_PROGRESS | 2026-07-13 |
| Normal rule parsing | Rule analyzer classes | `model/analyzeRule/**`, `model/webBook/**` | Dart rule engine | Controlled samples match Android output. | User samples needed | BLOCKED | 2026-07-13 |
| JavaScript rules | Rhino engine and source JS extensions | `modules/rhino/**`, `help/rhino/**`, `help/source/**` | `JsEngine` and Legado API bridge | JS samples pass on Android and iOS prototype. | User samples needed | BLOCKED | 2026-07-13 |
| Network and cookies | `HttpHelper`, `CookieManager`, WebView helpers | `help/http/**`, `help/webView/**` | Unified HTTP/cookie layer | Headers, cookies, charset, timeout, and errors are observable. | Codex | NOT_STARTED | 2026-07-13 |
| Search | `MainRouteSearch`, `SearchActivity` | `ui/book/search/**`, `SearchBooksUseCase.kt` | Search MVI and bounded coordinator | Normal-source code path supports incremental results/cancel/retry; real execution and JS pending. | Codex + user | IN_PROGRESS | 2026-07-14 |
| Book detail | `MainRouteBookInfo`, `BookInfoActivity` | `ui/book/info/**`, `WebBook.kt` | Book info MVI and detail service | Normal-source detail and add-to-shelf transaction implemented; user validation pending. | Codex + user | IN_PROGRESS | 2026-07-14 |
| Toc | `TocActivity` | `ui/book/toc/**`, `BookChapterDao.kt` | Toc embedded in book info | Pagination, URL dedupe, continuous index and persistence wired; user validation pending. | Codex + user | IN_PROGRESS | 2026-07-14 |
| Bookshelf | `MainScreen`, `BookShelfItem` | `ui/main/bookshelf/**`, `BookDao.kt`, `BookGroupDao.kt` | Bookshelf MVI, batch UseCases and refresh coordinator | Live list/grid, groups, six sorts, selection, refresh and delete implemented; user execution pending. | Codex + user | IN_PROGRESS | 2026-07-14 |
| Text reader | `MainRouteReadBook`, `ReadBookScreen` | `ui/book/read/**`, `model/ReadBook.kt`, `GetChapterContentUseCase.kt` | Reader MVI, coordinator, isolate processor and platform bridge | Vertical content, chapter switching, URL+character anchor, settings, bookmarks, replacement, cache and adjacent preload implemented; real device validation pending. | Codex + user | IN_PROGRESS | 2026-07-14 |
| Local book import and reading | `ImportBookScreen`, file associations | `ui/book/import/local/**`, `model/localBook/**`, `LocalBookRepository.kt`, `ArchiveUtils` | M8.1 local import MVI, shared parsers, secure file access and reader adapters | TXT/EPUB/UMD text reading and PDF page reading are implemented pending execution; MOBI family and archives still block M9. | Codex + user | IN_PROGRESS | 2026-07-14 |

## Deferred Features Kept in Scope

| Feature | Android Entry | Deferral Reason | Flutter Target | Owner | Status | Updated |
|---|---|---|---|---|---|---|
| RSS | `RssSourceActivity`, RSS routes | Not in first-wave default scope. | Later RSS feature set | Codex | NOT_STARTED | 2026-07-13 |
| AI chat and AI settings | `MainRouteAiChat`, AI config routes | Not in first-wave default scope; IM reversed-list rule must be preserved when migrated. | Later AI feature set | Codex | NOT_STARTED | 2026-07-13 |
| Manga reader | `ReadMangaActivity` | Text reader first. | Later manga reader | Codex | NOT_STARTED | 2026-07-13 |
| Audio and TTS | Audio/TTS activities and services | Platform-heavy, first wave excludes full ability. | Later audio/TTS feature set | Codex | NOT_STARTED | 2026-07-13 |
| Embedded web service | `WebService`, `web/**`, `modules/web/` | Long-running server differs on iOS. | Later web service feature set | Codex | NOT_STARTED | 2026-07-13 |
| Backup/WebDAV | Backup settings and storage helpers | First wave excludes old-data migration and full backup parity. | Later backup feature set | Codex | NOT_STARTED | 2026-07-13 |
| Full themes/icons | Theme config and launcher aliases | First wave needs unified Flutter visual system only. | Later personalization feature set | Codex | NOT_STARTED | 2026-07-13 |
| Advanced file manager and sharing | File manager, move/rename/share activities | Basic local-book picker and external-open import moved to M8.1; full general file management remains deferred. | Later platform feature set | Codex | NOT_STARTED | 2026-07-14 |

## Latest Schema 94 Table Coverage

| Table | First-Wave Role | Primary Key | Owner | Status | Updated |
|---|---|---|---|---|---|
| `books` | Core shelf and reader entity | `bookUrl` | Codex | IN_PROGRESS | 2026-07-13 |
| `book_sources` | Core source entity | `bookSourceUrl` | Codex | IN_PROGRESS | 2026-07-13 |
| `chapters` | Core toc/content entity | `url + bookUrl` | Codex | IN_PROGRESS | 2026-07-13 |
| `book_groups` | Core shelf grouping | `groupId` | Codex | IN_PROGRESS | 2026-07-13 |
| `searchBooks` | Core search result cache | `bookUrl` | Codex | IN_PROGRESS | 2026-07-13 |
| `bookmarks` | Core reader bookmark | `time` | Codex | IN_PROGRESS | 2026-07-13 |
| `cookies` | Core network/session storage | `url` | Codex | IN_PROGRESS | 2026-07-13 |
| `caches` | Core cache/key-value helper | `key` | Codex | IN_PROGRESS | 2026-07-13 |
| `replace_rules` | Reader text replacement | `id` | Codex | IN_PROGRESS | 2026-07-13 |
| `readRecord`, `readRecordDetail`, `readRecordSession` | Reading progress/history candidate | Composite/id | Codex | MAPPING | 2026-07-13 |
| All AI/RSS/TTS/dict/homepage/highlight/server tables | Deferred feature storage | Various | Codex | NOT_STARTED | 2026-07-13 |
