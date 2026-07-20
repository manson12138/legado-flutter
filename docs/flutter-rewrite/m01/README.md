# M01 Flutter Project Scaffold Output

Last updated: 2026-07-13

## Confirmed identifiers and SDK

| Item | Value | Status |
|---|---|---|
| Project directory | `flutter_app` | DONE |
| Display name | `Legado Flutter` | DONE |
| Android applicationId | `io.legado.flutter` | DONE |
| Android minSdk | `26` | DONE |
| iOS Bundle Identifier | `io.legado.flutter` | DONE |
| iOS Deployment Target | `16.0` | DONE |
| Flutter | `3.41.5 stable` | DONE |
| Dart | `3.11.3` | DONE |
| App icon | Reused from current Android launcher artwork | DONE |

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

See `flutter_app/README.md` for commands and manual acceptance steps.
