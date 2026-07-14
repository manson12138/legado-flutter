# M00 JavaScript Compatibility Spec

Last updated: 2026-07-13

## Compatibility Levels

| Level | Scope | Android Source | Flutter Target | Owner | Status | Updated |
|---|---|---|---|---|---|---|
| JS-L1 | ECMAScript syntax, built-ins, regex, JSON, Date, error stacks, timeout and interruption | `modules/rhino/**` | `JsEngine` abstraction and JSF/QuickJS prototype | Codex + user validation | IN_PROGRESS | 2026-07-13 |
| JS-L2 | Legado exposed APIs: `source`, `book`, `chapter`, `result`, Cookie, cache, network, tools | `help/rhino/NativeBaseSource.kt`, `help/source/**`, login JS extensions | Dart DTO, Proxy and API bindings | User samples needed | IN_PROGRESS | 2026-07-13 |
| JS-L3 | Common Rhino/Java compatibility calls used by real sources | Rhino wrappers and Java class shutter/wrap factory | Whitelisted `JavaCompatibilityBridge` | User samples needed | MAPPING | 2026-07-13 |

## Engine Selection Gate

| Criterion | Required Evidence Before M4 Exit | Owner | Status | Updated |
|---|---|---|---|---|
| Same Android/iOS engine strategy | JSF/QuickJS prototype selected; both real platforms still require execution proof. | Codex + user | IN_PROGRESS | 2026-07-13 |
| Dart object/function binding | DTO, Proxy, sync callback and Future/Promise bridge implemented. | Codex + user | IN_PROGRESS | 2026-07-13 |
| Timeout and interruption | Native timeout plus cancellation-to-interrupt prototype implemented; device timing pending. | User | IN_PROGRESS | 2026-07-13 |
| Stack traces | Classified and privacy-trimmed error report implemented; positions pending sample proof. | User | IN_PROGRESS | 2026-07-13 |
| Regex/date/encoding behavior | Required difference set documented; sample execution pending. | User | BLOCKED | 2026-07-13 |
| License and maintenance | JSF MIT and new 1.0 API risk recorded in M4 decision. | Codex | IN_PROGRESS | 2026-07-13 |
| Package size/native code | Android/iOS build implication recorded; size measurement pending. | User | BLOCKED | 2026-07-13 |

## Required Sample Set

| Sample Type | Needed Input | Expected Output | Sensitivity Rule | Owner | Status | Updated |
|---|---|---|---|---|---|---|
| Normal source | Sanitized source JSON and fixed keyword/book | Search/detail/toc/content outputs | Remove account, cookie, authorization, personal paths. | User | BLOCKED | 2026-07-13 |
| JS search | Source with JS search rule | Result list matching Android | Remove secrets. | User | BLOCKED | 2026-07-13 |
| JS detail | Source with JS detail rule | Detail fields matching Android | Remove secrets. | User | BLOCKED | 2026-07-13 |
| JS toc | Source with JS toc rule | Chapter list matching Android | Remove secrets. | User | BLOCKED | 2026-07-13 |
| JS content | Source with JS content rule | Chapter text matching Android | Remove private content if needed; keep deterministic fixture. | User | BLOCKED | 2026-07-13 |
| Header/Cookie | Source using custom headers/cookies | Cookie and header behavior matching Android | Do not commit live cookies. | User | BLOCKED | 2026-07-13 |
| Login/Captcha/WebView | Source needing interactive flow | Clear success/failure states | Use test account only, not secrets. | User | BLOCKED | 2026-07-13 |
| Java/Rhino API call | Source calling `java.*` or Android/Kotlin helper | Supported or explicit unsupported error | Record class and method names. | User | BLOCKED | 2026-07-13 |

## Script API Mapping Baseline

| API Surface | Android Reference | Flutter Target | Difference Policy | Owner | Status | Updated |
|---|---|---|---|---|---|---|
| Source object | `BookSource`, `NativeBaseSource` | Script-visible source wrapper | Script-visible names stay stable. | Codex + user | IN_PROGRESS | 2026-07-13 |
| Book object | `Book`, `SearchBook`, web book models | Script-visible book wrapper | Preserve field meaning and nullability. | Codex + user | IN_PROGRESS | 2026-07-13 |
| Chapter object | `BookChapter`, `BookChapterList` | Script-visible chapter wrapper | Preserve identity and chapter order. | Codex + user | IN_PROGRESS | 2026-07-13 |
| Network helpers | `HttpHelper`, `AnalyzeUrl`, `CustomUrl` | Unified HTTP facade | No script bypass around unified network layer. | Codex + user | IN_PROGRESS | 2026-07-13 |
| Cookie helpers | `CookieManager`, `CookieStore` | Unified cookie facade | Platform WebView sync documented. | Codex + user | IN_PROGRESS | 2026-07-13 |
| Java compatibility | Rhino Java wrappers | `JavaCompatibilityBridge` | Common calls only; unsupported calls fail with explicit error. | User samples needed | BLOCKED | 2026-07-13 |
