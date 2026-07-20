# M00 UI Spec

Last updated: 2026-07-13

## UI Equivalence Rules

| Rule | Android Reference | Flutter Requirement | Owner | Status | Updated |
|---|---|---|---|---|---|
| Functional parity over pixel parity | Rewrite plan section 28 | Preserve entry, hierarchy, operations, state, errors, and return behavior. | Codex | MAPPING | 2026-07-13 |
| Unified visual system | Rewrite plan section 29 | Android and iOS share Flutter components, not separate Material/Cupertino app trees. | Codex | MAPPING | 2026-07-13 |
| UDF/MVI page model | Current Compose contracts and rewrite plan | Screen receives state and sends intents; effects handle navigation/system actions. | Codex | MAPPING | 2026-07-13 |
| Long list stability | Compose list rules and rewrite plan | Use stable business IDs for keys. | Codex | MAPPING | 2026-07-13 |
| Reader first-wave mode | Rewrite plan section 34 | Vertical scroll is allowed first; data model must not block later page modes. | Codex | MAPPING | 2026-07-13 |
| Chat/IM reversed list | User AGENTS instruction | When AI chat/IM migrates, preserve bottom-newest reverse list semantics. | Codex | NOT_STARTED | 2026-07-13 |

## Required Tokens and Components

| Area | Required Baseline | Owner | Status | Updated |
|---|---|---|---|---|
| Tokens | `ColorToken`, `TypographyToken`, `SpacingToken`, `RadiusToken`, `ElevationToken`, `DurationToken`, `ReaderToken` | Codex | NOT_STARTED | 2026-07-13 |
| App components | `AppScaffold`, `AppTopBar`, `AppNavigationBar`, buttons, list tile, card, dialog, sheet, search bar | Codex | NOT_STARTED | 2026-07-13 |
| State components | Empty, error, loading, selection bar | Codex | NOT_STARTED | 2026-07-13 |
| Domain widgets | `BookCover`, `BookListItem`, `SourceListItem`, `SettingItem` | Codex | NOT_STARTED | 2026-07-13 |
| Reader widgets | Reader content, reader top/bottom controls, reader style sheet, toc entry | Codex | NOT_STARTED | 2026-07-13 |

## First-Wave Screen Behavior Baseline

| Screen | Android Entry | Required States | Key Actions | Owner | Status | Updated |
|---|---|---|---|---|---|---|
| Source list | `BookSourceActivity` | Loading, normal, empty, import error, selection | Import, enable/disable, group, edit, delete, debug entry | Codex + user | IN_PROGRESS | 2026-07-13 |
| Source edit | `BookSourceEditActivity` | Editing, validation error, save progress, save failure | Save, cancel/back, basic debug/login boundary | Codex + user | IN_PROGRESS | 2026-07-13 |
| Search | `SearchScreen` / `SearchActivity` | Idle, searching, partial results, empty, source errors, canceled | Search, cancel, filter scope, open detail | Codex | MAPPING | 2026-07-13 |
| Book detail | `BookInfoScreen` / `BookInfoActivity` | Loading, normal, toc error, source error | Load detail, add shelf, read, open toc, change source later | Codex | MAPPING | 2026-07-13 |
| Toc | `TocActivity`, `TocScreen` | Loading, normal, empty, refresh error | Jump chapter, refresh toc, return selected chapter | Codex | MAPPING | 2026-07-13 |
| Bookshelf | Main bookshelf area | Loading, normal list/grid, empty, selection, update state | Open book, open detail, group/sort, delete | Codex | MAPPING | 2026-07-13 |
| Reader | `ReadBookScreen`, `ReadView` | Loading chapter, content, chapter error, retry, menu visible, style sheet | Next/previous chapter, toc jump, bookmark, save progress, restore progress | Codex | MAPPING | 2026-07-13 |

## Accessibility and Layout Baseline

| Requirement | Flutter Acceptance | Owner | Status | Updated |
|---|---|---|---|---|
| Touch target | Interactive controls at least 44 logical pixels. | Codex | NOT_STARTED | 2026-07-13 |
| Text scaling | Normal UI supports system scaling; reader uses independent reader font settings. | Codex | NOT_STARTED | 2026-07-13 |
| Safe area | Handle Android edge-to-edge and iOS safe areas. | Codex | NOT_STARTED | 2026-07-13 |
| Dark mode | Text, icons, dividers, selected states remain legible. | Codex | NOT_STARTED | 2026-07-13 |
| Semantic labels | Icon-only actions expose labels. | Codex | NOT_STARTED | 2026-07-13 |
| Keyboard | Inputs and submit controls remain reachable. | Codex | NOT_STARTED | 2026-07-13 |
