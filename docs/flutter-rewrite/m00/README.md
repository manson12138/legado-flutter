# M00 Decisions and Migration Ledger Output

Last updated: 2026-07-13

This directory is the execution output for `steps/M00_DECISIONS_AND_MIGRATION_LEDGER.md`.

M00 scope:

- Build migration facts, rules, mappings, and acceptance baselines only.
- Do not create `flutter_app`.
- Do not change Android business code.
- Do not run build, test, lint, static analysis, or Flutter/Gradle checks.

## Deliverables

| Deliverable | File | Owner | Status | Updated |
|---|---|---|---|---|
| Project decisions and baseline facts | [01_project_decisions.md](./01_project_decisions.md) | Codex maintains, user confirms release identifiers | DONE | 2026-07-13 |
| Architecture boundaries | [02_architecture_boundaries.md](./02_architecture_boundaries.md) | Codex maintains, user reviews boundaries | IN_PROGRESS | 2026-07-13 |
| File and naming mapping | [03_file_mapping.md](./03_file_mapping.md) | Codex maintains during every phase | MAPPING | 2026-07-13 |
| Feature matrix | [04_feature_matrix.md](./04_feature_matrix.md) | Codex updates, user accepts scope | MAPPING | 2026-07-13 |
| UI spec | [05_ui_spec.md](./05_ui_spec.md) | Codex maintains, user accepts UX differences | MAPPING | 2026-07-13 |
| JavaScript compatibility spec | [06_js_compatibility_spec.md](./06_js_compatibility_spec.md) | Codex researches, user provides samples | BLOCKED | 2026-07-13 |
| Platform capability matrix | [07_platform_capability_matrix.md](./07_platform_capability_matrix.md) | Codex maintains, user accepts platform gaps | MAPPING | 2026-07-13 |
| Acceptance spec | [08_acceptance_spec.md](./08_acceptance_spec.md) | Codex writes, user runs and confirms | BLOCKED | 2026-07-13 |

## Current M00 Gate State

| Gate | Evidence | Owner | Status | Updated |
|---|---|---|---|---|
| Parent rewrite plan read | `../FLUTTER_REWRITE_EXECUTION_PLAN.md` read completely on 2026-07-13. | Codex | DONE | 2026-07-13 |
| Step index read | `../steps/MIGRATION_STEPS_INDEX.md` read on 2026-07-13. | Codex | DONE | 2026-07-13 |
| M00 step document read | `../steps/M00_DECISIONS_AND_MIGRATION_LEDGER.md` read on 2026-07-13. | Codex | DONE | 2026-07-13 |
| Android baseline scanned | Gradle, Manifest, Room database, routes, core feature files scanned read-only. | Codex | DONE | 2026-07-13 |
| M1 identifiers confirmed | User confirmed directory, display name, both identifiers, current stable SDK strategy, and icon reuse. | User | DONE | 2026-07-13 |
| Flutter project creation | Explicitly forbidden in M00. | Codex | NOT_APPLICABLE | 2026-07-13 |

## Known Conflicts and Corrections

| Item | Source | Current Finding | Owner | Status | Updated |
|---|---|---|---|---|---|
| Room schema version | Root AGENTS mentions version 85; `AppDatabase.kt` and schema directory show latest version 94. | Use version 94 as current migration baseline. | Codex | DONE | 2026-07-13 |
| Step index link in parent plan | Parent plan says `steps/MIGRATION_STEPS_INDEX.md` from its own directory, but actual path is `steps/MIGRATION_STEPS_INDEX.md`. | Use actual existing path under `docs/flutter-rewrite/steps/`. | Codex | DONE | 2026-07-13 |
| Module name spelling | Root tree has `baselineProfile`, Gradle includes project `:baselineprofile` mapped to `baselineProfile`. | Record both spelling forms when mapping Gradle modules. | Codex | DONE | 2026-07-13 |
| Application package naming | Kotlin namespace is `io.legado.app`; Android applicationId is `io.legato.kazusa`. | Flutter app uses confirmed independent id `io.legado.flutter`. | User | DONE | 2026-07-13 |
