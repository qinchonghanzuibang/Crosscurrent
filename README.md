# FeedFlow

> Follow everything. Read what matters.

FeedFlow is an independent, native personal intelligence feed for macOS. It
collects text-centric sources, preserves Items as evidence, connects related
coverage into revisioned Events, and produces a stable daily briefing.

FeedFlow is being built for macOS 15 and later on Apple silicon. The repository
contains a native SwiftUI/AppKit application, background Agent, authenticated
BrowserWorker, Share Extension, and a modular Swift package.

## Development

Requirements:

- Xcode 26 or newer
- Swift 6
- XcodeGen 2.46 or newer

Generate the checked-in Xcode project after changing `project.yml`:

```sh
xcodegen generate
```

Run package tests:

```sh
swift test --package-path Packages/FeedFlowKit
```

`Debug` and `Release` use the Developer-ID entitlement profiles. `Sandbox`
uses target-specific sandbox profiles for the feasibility matrix. The final
profile for each executable is selected only after its signed integration gate
passes; Share Extension is always sandboxed.

## Acknowledgements

PaperRss inspired aspects of AI-assisted reading interaction. NetNewsWire is a
reference for native feed UX and modular desktop architecture. FeedFlow is an
independent implementation: no PaperRss or NetNewsWire implementation code has
been copied, translated, or mechanically rewritten.

## License

MIT License. Copyright 2026 Chonghan Qin.
