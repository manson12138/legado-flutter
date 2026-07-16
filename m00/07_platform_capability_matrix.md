# M00 Platform Capability Matrix

Last updated: 2026-07-16

## First-Wave Capabilities

| Capability | Android Source | Flutter Android Direction | Flutter iOS Direction | Difference / Risk | Owner | Status | Updated |
|---|---|---|---|---|---|---|---|
| HTTP | `help/http/HttpHelper.kt`, OkHttp/Cronet | Dart HTTP first; plugin only if needed | Same Dart HTTP first | Cronet is Android-specific; charset/cookie behavior must be tested. | Codex | MAPPING | 2026-07-13 |
| Cookie store | `CookieManager.kt`, `CookieStore.kt` | Dart store + official Android WebView cookie manager | Dart store + WKHTTPCookieStore through official plugin | Code now syncs by domain before/after controlled pages; HttpOnly/third-party behavior needs device results. | Codex + user | IN_PROGRESS | 2026-07-16 |
| WebView | `BackstageWebView.kt`, login WebView | Official Android WebView login/script route | Official WKWebView login/script route | Timeout/cancel/delegate release implemented; login, captcha and web-process recovery need device results. | Codex + user | IN_PROGRESS | 2026-07-16 |
| JavaScript | `:modules:rhino` | Shared Dart JSF/QuickJS + Legado bridge | Same Dart JSF/QuickJS + Legado bridge | iOS cannot execute JVM classes; WebView page bridge now exists, S2～S7 still need device results. | User samples needed | BLOCKED | 2026-07-16 |
| Local book file import | `ImportBookScreen`, file associations, `LocalBook` | System picker followed immediately by app-private copy; external-open association pending | Document Picker current-readable result followed immediately by sandbox copy | No temporary absolute path is persisted; security-scoped provider lifetime still needs iOS device validation. | Codex + user | IN_PROGRESS | 2026-07-16 |
| QR/camera | `QrCodeActivity` | `mobile_scanner` with Android camera permission | `mobile_scanner` with iOS camera usage description | Permission denial now points to Settings or clipboard fallback; gallery QR and real-device validation remain. | Codex + user | IN_PROGRESS | 2026-07-16 |
| Reader keep screen on | `ReadBookController.keepScreenOn` | MethodChannel sets `FLAG_KEEP_SCREEN_ON` and restores original flag | MethodChannel pauses `isIdleTimerDisabled` in background, restores requested value on foreground, restores original on exit | Code implemented; real auto-lock timing needs device validation. | Codex + user | IN_PROGRESS | 2026-07-16 |
| Safe area/system bars | `toggleSystemBar`, reader Activity behavior | `SystemChrome` immersive sticky plus shared SafeArea | Same Flutter SafeArea; size changes reproject stable character anchor | Code implemented; Home Indicator, keyboard and gesture conflict need device validation. | Codex + user | IN_PROGRESS | 2026-07-16 |
| Whole-book source switching | `ChangeSourceSearchUseCase`, `ChangeBookSourceUseCase` | Shared Dart search, preview, migration and sqflite transaction | Same Dart state machine and transaction | No new native logic; behavior still depends on platform network/JS results and must be accepted Android first, then iOS. | Codex + user | IN_PROGRESS | 2026-07-16 |

## Android-Only or Risky Capabilities

| Capability | Android Source | iOS Equivalent | Flutter Policy | Owner | Status | Updated |
|---|---|---|---|---|---|
| Foreground services | `service/**` | Limited background modes | Defer unless first-wave critical; no shared business state in native service. | Codex | NOT_STARTED | 2026-07-13 |
| BroadcastReceiver | `receiver/**` | No direct equivalent | Replace with platform-specific intents/share extensions where needed. | Codex | NOT_STARTED | 2026-07-13 |
| Install APK | `REQUEST_INSTALL_PACKAGES` permission | Not available | Mark unsupported on iOS. | Codex | NOT_APPLICABLE | 2026-07-13 |
| Manage external storage | Manifest storage permissions | iOS document sandbox | Use document picker/app sandbox; no absolute path parity. | Codex | MAPPING | 2026-07-13 |
| Quick Settings tile | `WebTileService` | No direct equivalent | Deferred/platform unsupported. | Codex | NOT_STARTED | 2026-07-13 |
| Android Intent associations | Association activities | URL schemes/document types/share extension | Implement only needed import/share paths first. | Codex | MAPPING | 2026-07-13 |
| Firebase analytics/perf | Gradle dependencies | Available but optional | Not part of first wave unless user requests. | User | BLOCKED | 2026-07-13 |

## Manifest Inventory Summary

| Component Type | Android Components | First-Wave Relevance | Owner | Status | Updated |
|---|---|---|---|---|---|
| Launcher activities | `MainActivity`, `Launcher0` through `LauncherW` aliases | Flutter app uses independent launcher; alias parity deferred. | Codex | NOT_STARTED | 2026-07-13 |
| Core first-wave activities | `BookSourceActivity`, `BookSourceEditActivity`, `SearchActivity`, `BookInfoActivity`, `TocActivity`, reader routes/screens | Map to Flutter routes/screens. | Codex | MAPPING | 2026-07-13 |
| Import/association activities | `OnLineImportActivity`, `FileAssociationActivity`, `HandleFileActivity`, import dialogs | Needed for source/book import, but implementation will be platform-specific. | Codex | MAPPING | 2026-07-13 |
| Services | cache, export, web, TTS, audio, download services | Mostly deferred; cache/download may later need Android service. | Codex | NOT_STARTED | 2026-07-13 |
| Providers | `ReaderProvider`, `FileProvider`, startup provider | ReaderProvider deferred; FileProvider replaced by platform file plugin if needed. | Codex | NOT_STARTED | 2026-07-13 |
| Permissions | Internet, network, storage, foreground service, notification, audio, install package | First wave needs network, files, optional notifications later. | Codex | MAPPING | 2026-07-13 |
