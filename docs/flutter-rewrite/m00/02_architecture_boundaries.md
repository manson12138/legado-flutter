# M00 Architecture Boundaries

Last updated: 2026-07-13

## Target Boundary Rules

| Boundary | Rule | Android Source Reference | Flutter Target | Owner | Status | Updated |
|---|---|---|---|---|---|---|
| UI | Renders state and sends intents only. No direct DB, HTTP, file, source parsing, or JS execution. | `ui/**` | `lib/src/ui/**` | Codex | MAPPING | 2026-07-13 |
| ViewModel/Controller | Owns feature state, invokes use cases, emits one-shot effects. | Compose contracts and ViewModels under `ui/**` | `lib/src/ui/**/feature_view_model.dart` | Codex | MAPPING | 2026-07-13 |
| Domain | Holds gateway contracts, use cases, and platform-free business models. | `domain/**` | `lib/src/domain/**` | Codex | MAPPING | 2026-07-13 |
| Repository | Combines DAO, HTTP, file, JS, and platform APIs behind domain gateways. | `data/repository/**` | `lib/src/data/repository/**` | Codex | MAPPING | 2026-07-13 |
| DAO/local store | Owns persistence access only; UI must never call DAO. | `data/dao/**`, Room schema 94 | `lib/src/data/dao/**` | Codex | MAPPING | 2026-07-13 |
| Rule engine | Parses normal rules and routes JS rules through the JS abstraction. | `model/analyzeRule/**`, `model/webBook/**` | `lib/src/model/analyze_rule/**`, `lib/src/model/web_book/**` | Codex | MAPPING | 2026-07-13 |
| Network | Centralizes headers, cookies, redirects, charset, compression, timeout, and errors. | `help/http/**` | `lib/src/api/**` and `lib/src/data/local/**` | Codex | MAPPING | 2026-07-13 |
| Platform | Exposes narrow Android/iOS implementations behind Dart interfaces. | Manifest services, receivers, platform helpers | `lib/src/platform/**`, `packages/legado_platform/**` | Codex | MAPPING | 2026-07-13 |
| Native Kotlin/Swift | Cannot own long-lived cross-page business state. | Manifest services and Android helpers | Plugin implementations only | Codex | MAPPING | 2026-07-13 |

## First-Wave Architecture Scope

| Area | Include in First Wave | Exclude or Defer | Owner | Status | Updated |
|---|---|---|---|---|---|
| App shell | Routing, theme, DI, error boundary, empty first screen. | Full settings and account systems. | Codex | MAPPING | 2026-07-13 |
| Source management | Import, list, enable/disable, group, edit/delete basics, login entry if sample needs it. | Full debug parity and advanced batch tooling. | Codex | MAPPING | 2026-07-13 |
| Normal rules | JSONPath, XPath, CSS/JSoup-style selectors, Regex, URL/request options. | Unused historical quirks unless samples require them. | Codex | MAPPING | 2026-07-13 |
| JavaScript | Engine abstraction, Legado API surface, compatibility bridge prototype. | Claiming 100% Rhino/JVM compatibility. | User samples needed | BLOCKED | 2026-07-13 |
| Search/detail/toc | Multi-source search, detail parse, toc load, add to shelf. | Full source-change optimizations beyond first-wave need. | Codex | MAPPING | 2026-07-13 |
| Bookshelf | List/grid, group/sort basics, delete, progress display. | Full visual parity and every advanced management action. | Codex | MAPPING | 2026-07-13 |
| Text reader | Content load, vertical scroll, chapter switch, progress save/restore, basic style, bookmark, retry. | Full manga/audio/TTS/page-curl feature parity. | Codex | MAPPING | 2026-07-13 |

## Data Boundary Baseline

| Data Decision | Rule | Source | Owner | Status | Updated |
|---|---|---|---|---|---|
| Old Room migrations | Do not port historical Room migrations 1-94. | Rewrite plan section 22 | Codex | DONE | 2026-07-13 |
| Table naming | Prefer current schema 94 table and field names where semantically useful. | `app/schemas/.../94.json` | Codex | MAPPING | 2026-07-13 |
| First-wave tables | Start with books, sources, chapters, groups, search books, bookmarks, cookies, caches, replace rules, and core config. | Rewrite plan M2 | Codex | MAPPING | 2026-07-13 |
| Deferred tables | RSS, AI, HTTP TTS, dict, homepage, advanced highlighting, server tables remain in matrix. | Room schema 94 | Codex | MAPPING | 2026-07-13 |
| URL identity | Preserve Android semantics where URL is primary key; no silent lowercasing or trimming changes. | `books`, `book_sources`, `chapters` primary keys | Codex | MAPPING | 2026-07-13 |

## Platform Boundary Baseline

| Capability | Default Implementation Direction | Platform Risk | Owner | Status | Updated |
|---|---|---|---|---|---|
| HTTP and charset | Pure Dart or stable cross-platform package first. | Cookie/WebView synchronization differs per platform. | Codex | MAPPING | 2026-07-13 |
| WebView | Flutter plugin with platform adapters. | WKWebView and Android WebView differ in cookies and callbacks. | Codex | MAPPING | 2026-07-13 |
| JavaScript | Cross-platform engine prototype before mass migration. | iOS cannot run arbitrary JVM/Rhino Java APIs. | User samples needed | BLOCKED | 2026-07-13 |
| Files | Flutter/system pickers plus platform plugin where needed. | iOS sandbox cannot mirror Android external storage. | Codex | MAPPING | 2026-07-13 |
| Foreground services | Android native only if needed, no shared business state. | iOS background behavior is limited. | Codex | MAPPING | 2026-07-13 |

