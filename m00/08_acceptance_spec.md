# M00 Acceptance Spec

Last updated: 2026-07-13

## Stage Acceptance Rules

| Rule | Evidence Required | Owner | Status | Updated |
|---|---|---|---|---|
| M00 only creates baseline docs | No `flutter_app` project and no Android business edits. | Codex | DONE | 2026-07-13 |
| All first-wave entries have migration ownership | File mapping and feature matrix contain source/search/detail/toc/bookshelf/reader. | Codex | MAPPING | 2026-07-13 |
| Current Android baseline is frozen | Branch, commit, app ids, SDKs, modules, Room schema recorded. | User confirms commit | IN_PROGRESS | 2026-07-13 |
| Unknowns are not hidden | M1 identifiers and icon are confirmed; JS samples and user-run validation remain explicit later blockers. | User | IN_PROGRESS | 2026-07-13 |
| No checks run by AI | User instruction and rewrite plan forbid AI-run checks. | Codex | DONE | 2026-07-13 |

## First-Wave End-to-End Acceptance Path

| Step | User Action | Expected Result | Android Result | iOS Result | Owner | Status | Updated |
|---|---|---|---|---|---|---|---|
| 1 | Install new Flutter app | App launches with Flutter shell. | Not run | Not run | User | NOT_STARTED | 2026-07-13 |
| 2 | Import sanitized real book source | Source appears in source list or shows clear error. | Not run | Not run | User | NOT_STARTED | 2026-07-13 |
| 3 | Search keyword | Results stream in with source/error visibility. | Not run | Not run | User | NOT_STARTED | 2026-07-13 |
| 4 | Open detail | Book detail fields and toc/detail data load. | Not run | Not run | User | NOT_STARTED | 2026-07-13 |
| 5 | Add to shelf | Book is persisted and visible on shelf. | Not run | Not run | User | NOT_STARTED | 2026-07-13 |
| 6 | Open toc | Chapter list opens and supports selection. | Not run | Not run | User | NOT_STARTED | 2026-07-13 |
| 7 | Read content | Chapter text renders with basic reader controls. | Not run | Not run | User | NOT_STARTED | 2026-07-13 |
| 8 | Switch chapter | Next/previous or toc jump loads expected chapter. | Not run | Not run | User | NOT_STARTED | 2026-07-13 |
| 9 | Exit and reopen | Book and reading position restore. | Not run | Not run | User | NOT_STARTED | 2026-07-13 |
| 10 | Import TXT/EPUB/UMD/PDF local books | Private copies open and restore text/page progress. | Not run | Not run | User | NOT_STARTED | 2026-07-14 |
| 11 | Import MOBI/AZW and ZIP/RAR/7Z entries | Supported books import; DRM/malicious input is rejected explicitly. | Blocked by M8.1 | Not run | Codex + user | BLOCKED | 2026-07-14 |

## M1 Entry Checklist

| Requirement | Current Value | Owner | Status | Updated |
|---|---|---|---|---|
| Flutter directory confirmed | `flutter_app` | User | DONE | 2026-07-13 |
| Display name confirmed | `Legado Flutter` | User | DONE | 2026-07-13 |
| Android applicationId confirmed | `io.legado.flutter` | User | DONE | 2026-07-13 |
| iOS bundle identifier confirmed | `io.legado.flutter` | User | DONE | 2026-07-13 |
| Icon decision confirmed | Reuse current icon | User | DONE | 2026-07-13 |
| JS samples plan confirmed | Sanitized source JSON set | User | BLOCKED | 2026-07-13 |
| M00 docs accepted | User replied “全部确认” before M1 execution. | User | DONE | 2026-07-13 |

## User-Run Checks

M00 contains Markdown documentation only, so no build, lint, test, Gradle, Dart, or Flutter command is required for this stage.

| Check | Command | Who Runs | Status | Updated |
|---|---|---|---|---|
| Markdown/manual review | Open and review `docs/flutter-rewrite/m00/README.md` | User | NOT_STARTED | 2026-07-13 |
| Git decision | Decide whether to stage new M00 docs | User | BLOCKED | 2026-07-13 |
