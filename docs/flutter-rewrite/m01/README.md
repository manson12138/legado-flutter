# M01 Flutter Project Scaffold Output

Last updated: 2026-08-03

## Confirmed identifiers and SDK

| Item | Value | Status |
|---|---|---|
| Project directory | Repository root after the Flutter/Android split | DONE |
| Display name | `PageNest（拾页）` | DONE |
| Android applicationId | `com.contradiction.pagenest` | DONE |
| Android minSdk | `26` | DONE |
| iOS Bundle Identifier | `com.contradiction.pagenest` | DONE |
| iOS Deployment Target | `16.0` | DONE |
| Flutter | `3.41.5 stable` | DONE |
| Dart | `3.11.3` | DONE |
| Chinese / English name | `拾页` / `PageNest` | DONE |
| Dart package name | `pagenest` | DONE |
| App icon | Original PageNest open-page and starlight artwork; Android/iOS size sets share one master | DONE |
| Android signing | New `pagenest` RSA 4096-bit release key; private files are local-only and ignored by Git | DONE |

## Architecture decisions

| Area | M1 choice | Reason | Status |
|---|---|---|---|
| Routing | Flutter SDK `onGenerateRoute` | One route does not justify a third-party dependency; route names and wiring are centralized. | IN_PROGRESS |
| Dependency injection | Composition root plus constructor injection | Keeps dependencies explicit and avoids a global Service Locator. | IN_PROGRESS |
| State model | UiState, Intent, Effect, ViewModel, Route, Screen | Preserves MVI/UDF boundaries and keeps system UI effects out of long-term state. | IN_PROGRESS |
| Theme | Shared Material 3 plus Design Token | Android and iOS use one visual system while platform system UI remains native. | IN_PROGRESS |
| Error handling | App error/result model plus framework, dispatcher, and zone handlers | Recoverable errors stay in feature state; uncaught failures have a final safe boundary. | IN_PROGRESS |
| Logging | `AppLogger` abstraction with debug-only console implementation | Callers do not depend on an output backend and sensitive values are excluded by contract. | IN_PROGRESS |

No third-party runtime package was added. `flutter create` ran with `--no-pub`, so dependency resolution and lockfile generation remain user actions.

## Current gate state

All M1 source and host configuration is implemented, but no analyze, test, build, or run command was executed. Status remains `IN_PROGRESS` until the user runs Android and confirms A0, or explicitly accepts continuing without validation.

See the repository-root `README.md` for commands and manual acceptance steps.

## 2026-08-03 PageNest identity replacement

The user explicitly replaced the complete Flutter product identity. Android now uses
`com.contradiction.pagenest` for both `namespace` and `applicationId`; iOS uses the same value as
its Bundle Identifier. Chinese launchers display `拾页`, while non-Chinese launchers display
`PageNest`. Platform channel names moved to the same namespace on Dart, Kotlin, and Swift.

The old tracked Android signing material was removed. A new local-only signing pair was generated
at `android/pagenest-signing.properties` and `android/app/signing/pagenest_release.jks`; neither file
may be staged. This creates a new install identity and intentionally provides no overwrite or data
migration path from the previous Flutter package.
