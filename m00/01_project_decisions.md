# M00 Project Decisions and Baseline Facts

Last updated: 2026-07-13

## Frozen Baseline

| Fact | Value | Source | Owner | Status | Updated |
|---|---|---|---|---|---|
| Repository path | `/Users/ocean/Desktop/code/_git/legado-with-MD3` | Current workspace | Codex | DONE | 2026-07-13 |
| Git branch | `main` | `git branch --show-current` | Codex | DONE | 2026-07-13 |
| Git commit | `307f2a45f6d7ccef146562d4c60081aafcb887a8` | `git rev-parse HEAD` | User confirms long-term baseline | IN_PROGRESS | 2026-07-13 |
| Rewrite output location | Same Git repository as Android project | Confirmed in rewrite plan | User | DONE | 2026-07-13 |
| Flutter project directory | `flutter_app` | User confirmed before M1 | User | DONE | 2026-07-13 |
| Flutter display name | `Legado Flutter` | User confirmed before M1 | User | DONE | 2026-07-13 |
| Flutter Android applicationId | `io.legado.flutter` | User confirmed before M1 | User | DONE | 2026-07-13 |
| Flutter iOS bundle identifier | `io.legado.flutter` | User confirmed before M1 | User | DONE | 2026-07-13 |
| Android-first order | Android A2 first, then iOS A2 | Confirmed in rewrite plan | User | DONE | 2026-07-13 |
| Old app data migration | Do not read or migrate old private database | Confirmed in rewrite plan | User | DONE | 2026-07-13 |
| First-wave scope | Source, search, detail, shelf, text reader, progress restore | Confirmed in rewrite plan | User | DONE | 2026-07-13 |
| Flutter project creation | Not allowed in M00 | M00 step document | Codex | NOT_APPLICABLE | 2026-07-13 |

## Android App Baseline

| Fact | Value | Source | Owner | Status | Updated |
|---|---|---|---|---|---|
| Android namespace | `io.legado.app` | `app/build.gradle.kts` | Codex | DONE | 2026-07-13 |
| Android applicationId | `io.legato.kazusa` | `app/build.gradle.kts` | Codex | DONE | 2026-07-13 |
| Compile SDK | 37 | `app/build.gradle.kts` | Codex | DONE | 2026-07-13 |
| Min SDK | 26 | `app/build.gradle.kts` | Codex | DONE | 2026-07-13 |
| Target SDK | 37 | `app/build.gradle.kts` | Codex | DONE | 2026-07-13 |
| Room database class | `io.legado.app.data.AppDatabase` | `AppDatabase.kt` | Codex | DONE | 2026-07-13 |
| Room database name | `legado.db` | `AppDatabase.kt` | Codex | DONE | 2026-07-13 |
| Latest Room schema | 94 | `AppDatabase.kt`, `app/schemas/.../94.json` | Codex | DONE | 2026-07-13 |
| Gradle modules | `:app`, `:modules:book`, `:modules:rhino`, `:baselineprofile` | `settings.gradle` | Codex | DONE | 2026-07-13 |
| Android UI state | Hybrid Compose and View | Manifest and `ui/` files | Codex | DONE | 2026-07-13 |
| Core JS engine | Rhino wrapper in `:modules:rhino` | `modules/rhino/src/main/java/com/script` | Codex | DONE | 2026-07-13 |
| Web frontend | Vue/Vite under `modules/web/` | repository tree | Codex | DONE | 2026-07-13 |

## Top Package Inventory

| Package | Kotlin/Java File Count | Migration Meaning | Owner | Status | Updated |
|---|---:|---|---|---|---|
| `api` | 7 | Android provider/API surfaces; mostly deferred beyond first wave. | Codex | MAPPING | 2026-07-13 |
| `base` | 24 | Android Activity/Fragment/ViewModel bases; concept only for Flutter architecture. | Codex | MAPPING | 2026-07-13 |
| `constant` | 13 | Shared constants that need Dart mapping where business-visible. | Codex | MAPPING | 2026-07-13 |
| `data` | 149 | Room entities, DAO, repositories; first-wave core data source. | Codex | MAPPING | 2026-07-13 |
| `di` | 2 | Koin registrations; concept maps to Flutter composition root. | Codex | MAPPING | 2026-07-13 |
| `domain` | 79 | Gateway/usecase layer; preferred semantic source for Dart domain. | Codex | MAPPING | 2026-07-13 |
| `exception` | 8 | Error model candidates for Dart domain errors. | Codex | MAPPING | 2026-07-13 |
| `help` | 99 | HTTP, source, JS, storage, utility glue; first-wave source/network/JS mapping. | Codex | MAPPING | 2026-07-13 |
| `lib` | 107 | Android wrappers and legacy libraries; evaluate platform bridge or defer. | Codex | MAPPING | 2026-07-13 |
| `model` | 51 | Runtime coordinators and analyzers; first-wave rule/reader mapping. | Codex | MAPPING | 2026-07-13 |
| `receiver` | 4 | Android-only broadcast/process text surfaces; mostly platform matrix. | Codex | MAPPING | 2026-07-13 |
| `service` | 11 | Android foreground/background services; mostly deferred or platform-specific. | Codex | MAPPING | 2026-07-13 |
| `ui` | 687 | Compose/View screens; source for behavior and entry mapping. | Codex | MAPPING | 2026-07-13 |
| `utils` | 106 | Extension and helper behavior; map only where used by first-wave features. | Codex | MAPPING | 2026-07-13 |
| `web` | 6 | Embedded HTTP server integration; deferred first wave. | Codex | MAPPING | 2026-07-13 |

## M1 Confirmation Record

| Decision | Confirmed Value | Decision Note | Owner | Status | Updated |
|---|---|---|---|---|---|
| Flutter directory | `flutter_app` | Confirmed as the repository-local project path. | User | DONE | 2026-07-13 |
| App display name | `Legado Flutter` | Confirmed for Android and iOS launcher metadata. | User | DONE | 2026-07-13 |
| Android applicationId | `io.legado.flutter` | Confirmed and distinct from `io.legato.kazusa`. | User | DONE | 2026-07-13 |
| iOS bundle identifier | `io.legado.flutter` | Confirmed for the Runner signing target. | User | DONE | 2026-07-13 |
| App icon | Reuse current icon | Confirmed; M1 converts existing launcher artwork for both hosts. | User | DONE | 2026-07-13 |
| JS compatibility samples | User-provided sanitized source JSON set | M4 cannot claim compatibility without real samples. | User | BLOCKED | 2026-07-13 |
