# M00 Platform Capability Matrix

Last updated: 2026-07-14

## First-Wave Capabilities

| Capability | Android Source | Flutter Android Direction | Flutter iOS Direction | Difference / Risk | Owner | Status | Updated |
|---|---|---|---|---|---|---|---|
| HTTP | `help/http/HttpHelper.kt`, OkHttp/Cronet | Dart HTTP first; plugin only if needed | Same Dart HTTP first | Cronet is Android-specific; charset/cookie behavior must be tested. | Codex | MAPPING | 2026-07-13 |
| Cookie store | `CookieManager.kt`, `CookieStore.kt` | Dart store plus Android WebView sync | Dart store plus WKWebView sync | Cross-WebView sync differs. | Codex | MAPPING | 2026-07-13 |
| WebView | `BackstageWebView.kt`, login WebView | Flutter WebView plugin/platform adapter | WKWebView adapter | JS bridge and cookies differ. | Codex | MAPPING | 2026-07-13 |
| JavaScript | `:modules:rhino` | Candidate engine or plugin | Same strategy required where possible | iOS cannot execute JVM classes. | User samples needed | BLOCKED | 2026-07-13 |
| Local book file import | `ImportBookScreen`, file associations, `LocalBook` | System picker followed immediately by app-private copy; external-open association pending | Same picker boundary and sandbox copy; M10 must validate security-scoped source lifetime | No temporary absolute path is persisted; database stores only a private relative path and SHA-256 identity. | Codex + user | IN_PROGRESS | 2026-07-14 |
| QR/camera | `QrCodeActivity` | `mobile_scanner` with Android camera permission | `mobile_scanner` with iOS camera usage description | Camera QR text/URL source import implemented; gallery QR and real-device permission/rotation validation remain. | Codex + user | IN_PROGRESS | 2026-07-14 |
| Reader keep screen on | `ReadBookController.keepScreenOn` | MethodChannel sets `FLAG_KEEP_SCREEN_ON` and restores original flag | MethodChannel sets `isIdleTimerDisabled` and restores original value | Code implemented; real auto-lock timing needs device validation. | Codex + user | IN_PROGRESS | 2026-07-14 |
| Safe area/system bars | `toggleSystemBar`, reader Activity behavior | `SystemChrome` immersive sticky plus shared SafeArea | Same Flutter system UI and SafeArea policy | Code implemented; gesture conflict and restoration need device validation. | Codex + user | IN_PROGRESS | 2026-07-14 |

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
