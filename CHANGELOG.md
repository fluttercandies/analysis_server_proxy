## 0.1.0

- Bound large-message fixture memory without reducing its 120 MB framing workload.
- Add README development checks and bilingual troubleshooting/removal steps.

- Add transparent LSP forwarding and authenticated analyzer bridge checks.
- Use compiled `.dill` files with `dart.analyzerPath`; remove the retired
  SDK snapshot replacement installer, restore commands and launch modes.
- Add generated command help.
- Add `analyzer-path` to compile the proxy for `dart.analyzerPath`.
- Compile with the activation's package config, so
  `analyzer-path` works for packages activated from pub.dev or git.
