# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

This repository was extracted (with full commit history) from `flutter_app/` and
`docs/flutter-rewrite/` inside the `legado-with-MD3` Android monorepo. The Android project remains
the read-only reference implementation this Flutter rewrite is built against; it now lives in a
sibling repository rather than a parent directory. See `AGENTS.md` for the full set of Flutter
rewrite process rules (AI usage order, read-only Android boundary, index maintenance).

## Database Schema Changes

This Flutter app has its own independent SQLite database
(`lib/src/data/local/legado_database.dart`), separate from the Android Room database in the sibling
`legado-with-MD3` repository.

Whenever a change touches persisted data (new/changed/removed table columns, new tables, changed
constraints — typically anything under `lib/src/domain/model/` that maps to a DB row), you must:

1. Check whether `LegadoDatabase.schemaVersion` needs to increase. If the new/changed field must
   exist in the SQLite schema (not just an in-memory default), bump `schemaVersion`, add the column
   to the relevant `CREATE TABLE` (the base schema built in `onCreate`) for fresh installs, and add
   a matching `ALTER TABLE` under a new `if (oldVersion < N)` branch in `onUpgrade` for existing
   installs.
2. If `schemaVersion` was bumped, also bump `pubspec.yaml`'s `version:` build number
   (the integer after `+`) in the same change, so a schema-changing build is always distinguishable
   by its app version. Bump the semantic version part too if the change is user-facing.

Read `docs/flutter-rewrite/AI_PROJECT_INDEX.md` before any change for the full set of Flutter-specific
rules and current architecture facts.
