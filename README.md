# dart_analysis_server_proxy

[![pub package](https://img.shields.io/pub/v/dart_analysis_server_proxy.svg)](https://pub.dev/packages/dart_analysis_server_proxy) [![GitHub stars](https://img.shields.io/github/stars/fluttercandies/analysis_server_proxy)](https://github.com/fluttercandies/analysis_server_proxy/stargazers) [![GitHub forks](https://img.shields.io/github/forks/fluttercandies/analysis_server_proxy)](https://github.com/fluttercandies/analysis_server_proxy/network) [![GitHub license](https://img.shields.io/github/license/fluttercandies/analysis_server_proxy)](https://github.com/fluttercandies/analysis_server_proxy/blob/main/LICENSE) [![GitHub issues](https://img.shields.io/github/issues/fluttercandies/analysis_server_proxy)](https://github.com/fluttercandies/analysis_server_proxy/issues) <a href="https://qm.qq.com/q/ZyJbSVjfSU">![FlutterCandies QQ 群](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffluttercandies%2F.github%2Frefs%2Fheads%2Fmain%2Fdata.yml&query=%24.qq_group_number&label=QQ%E7%BE%A4&logo=qq&color=1DACE8)</a>

English | [简体中文](README-CN.md)

A transparent LSP proxy between Dart-Code and the Dart analysis server. It
lets [`dana`](https://pub.dev/packages/dart_analysis_daemon), CLI tools and AI
agents reuse the analyzer your IDE has already warmed up, instead of starting
another one that costs minutes and gigabytes.

The IDE behaves exactly as before: every LSP message is forwarded unchanged.
The proxy itself uses well under 100 MB and does not change the analyzer's
memory. Dart-Code, the Dart SDK and the analysis server are not modified.

Supported platforms: macOS and Windows.

## How it works

```text
Dart-Code  <->  proxy  <->  Dart analysis server
                  ^
                  | authenticated loopback bridge
                 dana
```

After the IDE initializes, the proxy writes `.dart_tool/dana-ide-bridge.json`
in each workspace root. `dana` finds it, connects with the token in it, and
asks for diagnostics the IDE analyzer already holds.

## Setup

```sh
dart pub global activate dart_analysis_server_proxy
dana_analysis_server analyzer-path --output <dir>/dana_analysis_server_proxy.dill
```

`analyzer-path` compiles the proxy with the current Dart SDK, writes it where
you ask, and prints the setting to add. Put `dart.analyzerPath` in one of
these places and restart the analyzer:

| Scope | Setting goes in | Relative path starts from | Applies to |
| ----- | --------------- | ------------------------- | ---------- |
| Single project | the project's `.vscode/settings.json` (can be committed) | the project folder | windows that open this project as a single folder; ignored in multi-root windows |
| Multi-project | the `settings` block of a `.code-workspace` file | the workspace file's directory | windows opened through that file, all of their folders |
| Global | user settings, absolute or `~/` path | — | every window |

A project or workspace setting overrides the global one. Example for a
workspace file next to the project folder:

```jsonc
// ~/work/app.code-workspace
{
  "folders": [{ "path": "app" }, { "path": "../shared_lib" }],
  "settings": {
    "dart.analyzerPath": "app/tool/dana/dana_analysis_server_proxy.dill"
  }
}
```

Things to know:

- The `.dill` file only loads on the Dart SDK that compiled it. Run
  `analyzer-path` again after changing the SDK. If the file is missing or
  cannot be loaded, Dart-Code reports an error and the analyzer does not start.
- A team can commit the `.dill` file (about 8 MB) with the project setting when
  everyone uses the same SDK, for example through FVM; regenerate it in the
  same change that bumps the SDK. For personal use, `.dart_tool/dana/` is
  git-ignored but removed by `flutter clean`.
- To check it is active: the analyzer process runs your `.dill` with `--lsp`
  and `.dart_tool/dana-ide-bridge.json` exists. Without the proxy the process
  is `dart language-server --protocol=lsp` and there is no bridge file.
- To go back, remove the setting and restart the analyzer.

## Using it with dana

```sh
# Require the IDE analyzer (exit 69 when no bridge is available).
dana check --root path/to/project --mode full --reuse-ide require
dana check --root path/to/project --files lib/main.dart --reuse-ide require
```

With the default `--reuse-ide auto`, `dana` uses the bridge when present and
its own session otherwise.

- Results reflect the IDE's current state, unsaved edits included. Use
  `--reuse-ide never` when a gate must check only what is on disk.
- Right after the IDE starts or reloads, plugins may still be loading and
  publish nothing for a while, so a settled result can lack plugin lints. If
  you rely on plugin lints, keep a file that always yields one plugin
  diagnostic and retry while it is missing.

## The bridge

- `status`, `check` for given files or folders, and `fullCheck` for the whole
  root, answered from the diagnostics the IDE analyzer has published; nothing
  is re-analyzed.
- `fullCheck` first tells the analyzer about Dart files changed since it was
  last idle, waits for the analysis pass, then waits until no diagnostics have
  arrived for 2 seconds, because plugins publish after the server goes idle.
  That last wait is capped (default 180 s, per request via
  `settleLimitSeconds`, 1–3600); reaching it answers `settled: false`.
- One endpoint per workspace root, each with its own token; results are
  limited to that root. The bridge listens on loopback only, cannot shut the
  analyzer down and never changes the IDE's unsaved content.

## Environment variables

| Variable | Default | Effect |
| -------- | ------- | ------ |
| `DANA_PROXY_LOG` | unset | also append proxy diagnostics (upstream start failures and exits, upstream stderr, LSP framing errors) to this file; they always go to stderr |
| `DANA_ANALYSIS_TIMEOUT_SECONDS` | 1800 | limit for upstream requests and `fullCheck` waits; `0` disables it |
| `DANA_DART_EXECUTABLE` | discovered | Dart runtime used to start the upstream analyzer when the proxy runs as a native executable; otherwise `DART_SDK`, `FLUTTER_ROOT` and `PATH` are tried |

## Commands

Run `dana_analysis_server --help` or `dana_analysis_server help <command>`.
Arguments that are not one of its commands are forwarded to the analyzer
unchanged; the proxy option `--upstream-executable <dart>` goes before `--`,
for example `dana_analysis_server --upstream-executable <dart> -- --lsp`.

## SDK changes and removal

After changing SDK, rerun `analyzer-path` with that SDK and restart the IDE
analyzer.

To uninstall, remove `dart.analyzerPath` from the settings where it was
configured and restart the analyzer, then run
`dart pub global deactivate dart_analysis_server_proxy`.
