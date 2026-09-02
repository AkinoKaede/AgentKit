# Repository Guidelines

## Project Structure & Module Organization

AgentKit is a Swift Package Manager library for macOS 15+ and iOS 18+. Core runtime code lives in `Sources/AgentKit`, organized by responsibility: `Core`, `Runtime`, `Providers`, `Tools`, `MCP`, `Security`, and `Services`. The optional ScrubberKit-backed web client is isolated in `Sources/AgentKitScrubber`. Tests are in `Tests/AgentKitTests`, and editable localization source is in `Localizations/Localizable.xcstrings`. Treat `Sources/AgentKit/Resources/*.lproj` as generated, committed output.

## Build, Test, and Development Commands

- `swift build` — resolve dependencies and compile both library products.
- `swift test` — build and run the complete Swift Testing suite.
- `swift format lint --recursive --strict Sources Tests Package.swift` — enforce `.swift-format` rules without changing files.
- `swift format format --recursive --in-place Sources Tests Package.swift` — apply the repository formatter.
- `Scripts/check-zh-localization.sh` — validate the string catalog and Simplified Chinese spacing/completeness; requires `jq`.
- `Scripts/build-localizations.sh` — regenerate committed `.strings`/`.stringsdict` resources with `xcrun xcstringstool` after catalog edits.

## Coding Style & Naming Conventions

Use Swift 6 language mode, four-space indentation, and a 120-column limit. Follow standard Swift naming: `UpperCamelCase` for types, `lowerCamelCase` for members, and filenames matching their principal type or feature. Keep public APIs explicitly `Sendable` and concurrency-safe where appropriate; this package uses nonisolated-by-default isolation and enables `ExistentialAny`. Preserve the existing responsibility-based directory boundaries, and document public behavior or non-obvious safety invariants with concise `///` comments.

## Testing Guidelines

Tests use Swift Testing (`import Testing`), with `@Suite`, `@Test`, and `#expect`. Name files `FeatureTests.swift` and test functions after observable behavior, for example `scratchFetchNeedsBothItsGroups()`. Add focused regression tests for provider adapters, tool scheduling, transcript repair, authorization, and localization changes. No formal coverage threshold is configured; new behavior should include success and failure-path coverage.

## Commit & Pull Request Guidelines

Recent history uses short, imperative subjects such as `Add an optional ScrubberKit-backed web client`. Keep each commit focused and explain the behavioral reason in the body when safety or concurrency semantics change. Pull requests should summarize the change, call out API or security implications, list validation performed, and link relevant issues. Include screenshots only for rendered localization or downstream UI effects. Commit regenerated localization resources whenever the catalog changes.
