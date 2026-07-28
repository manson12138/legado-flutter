# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

This repository was extracted (with full commit history) from `flutter_app/` and
`docs/flutter-rewrite/` inside the `legado-with-MD3` Android monorepo. The Android project remains
the read-only reference implementation this Flutter rewrite is built against; it now lives in a
sibling repository rather than a parent directory.

## Flutter Project Instructions

Before any task, read `docs/flutter-rewrite/FLUTTER_REWRITE_EXECUTION_PLAN.md` first, then use
`docs/flutter-rewrite/AI_PROJECT_INDEX.md` to locate the relevant implementation, Android reference
files, phase records, known blockers, and additional required documents.

For rewrite tasks:

- Treat `docs/flutter-rewrite/AI_PROJECT_INDEX.md` as a navigation index, not as a replacement for
  the current user request, this file, source facts, phase gates, or acceptance evidence.
- Also read `docs/flutter-rewrite/steps/MIGRATION_STEPS_INDEX.md` and the target phase document
  before implementing phase work.
- Do not run Flutter/Dart/Gradle/Xcode builds, tests, analysis, lint, formatting checks, or app
  startup; the user runs verification.
- Treat the original Android implementation (in the sibling `legado-with-MD3` repository) as
  read-only reference unless the user explicitly asks to modify it there.
- Re-evaluate the AI index when stable routes, layers, gateways, database schema, platform bridges,
  supported formats, or phase gates change.
- Whenever a change touches persisted data (new/changed/removed table columns, new tables, changed
  constraints), check whether `LegadoDatabase.schemaVersion`
  (`lib/src/data/local/legado_database.dart`) needs to increase — add the column to the
  base `CREATE TABLE` for fresh installs and a matching `ALTER TABLE` under a new
  `if (oldVersion < N)` branch in `onUpgrade` for existing installs. If `schemaVersion` was bumped,
  also bump `pubspec.yaml`'s `version:` build number (the integer after `+`) in the same
  change, so a schema-changing build is always distinguishable by its app version.
- Before adding or changing persisted data, explicitly choose storage by semantics: use MMKV for
  small, independent, frequently read key-value preferences that need no relational query or
  transaction; use SQLite for relational/list data, filtered queries, transactional state, queues,
  user-scoped business records, and large or expiring content; use Keychain/Keystore-backed secure
  storage for tokens and credentials. Do not put large chapter content, passwords, cookies,
  authorization data, or business queues in MMKV.
- New MMKV-backed data must define a stable namespaced key, device/user scope, default and corrupt
  value behavior, migration source and version, deletion/invalidation lifecycle, and privacy
  boundary. UI and business ViewModels must depend on a typed project store, not directly on the
  MMKV plugin.
- Whenever Codex creates a new hand-written file under this repository or
  `docs/flutter-rewrite/`, update the relevant section of
  `docs/flutter-rewrite/AI_PROJECT_INDEX.md` in the same task so the new file can be found by its
  responsibility, feature, route, call chain, platform boundary, or phase. A one-row-per-file list
  is not required when the existing feature entry already provides a clearer index.
- Generated files and build outputs are excluded from the index and must not be treated as project
  implementation sources.

Note: `docs/flutter-rewrite/` still contains many internal path references written as
`flutter_app/lib/...` from when this project lived inside the Android monorepo (e.g.
`flutter_app/pubspec.yaml`, `flutter_app/lib/src/...`). Those paths now resolve one level too deep —
the `flutter_app/` prefix should be dropped when following them. This has not been swept yet; treat
mismatches as a known, not-yet-cleaned-up artifact of the split rather than a source-of-truth
conflict.
