# dart_analysis_server_proxy

[![pub package](https://img.shields.io/pub/v/dart_analysis_server_proxy.svg)](https://pub.dev/packages/dart_analysis_server_proxy) [![GitHub stars](https://img.shields.io/github/stars/fluttercandies/analysis_server_proxy)](https://github.com/fluttercandies/analysis_server_proxy/stargazers) [![GitHub forks](https://img.shields.io/github/forks/fluttercandies/analysis_server_proxy)](https://github.com/fluttercandies/analysis_server_proxy/network) [![GitHub license](https://img.shields.io/github/license/fluttercandies/analysis_server_proxy)](https://github.com/fluttercandies/analysis_server_proxy/blob/main/LICENSE) [![GitHub issues](https://img.shields.io/github/issues/fluttercandies/analysis_server_proxy)](https://github.com/fluttercandies/analysis_server_proxy/issues) <a href="https://qm.qq.com/q/ZyJbSVjfSU">![FlutterCandies QQ 群](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffluttercandies%2F.github%2Frefs%2Fheads%2Fmain%2Fdata.yml&query=%24.qq_group_number&label=QQ%E7%BE%A4&logo=qq&color=1DACE8)</a>

[English](README.md) | 简体中文

位于 Dart-Code 与 Dart analysis server 之间的透明 LSP proxy。它让
[`dana`](https://pub.dev/packages/dart_analysis_daemon)、命令行工具和 AI Agent 复用 IDE
已经预热好的 analyzer，不用再另起一个要花几分钟、占好几 GB 内存的分析进程。

IDE 的行为和原来完全一样：所有 LSP 消息都原样转发。proxy 本身占用远低于 100 MB，也不改变
analyzer 的内存占用。不修改 Dart-Code、Dart SDK 和 analysis server。

支持平台：macOS、Windows。

## 工作方式

```text
Dart-Code  <->  proxy  <->  Dart analysis server
                  ^
                  | 带鉴权的本地回环 bridge
                 dana
```

IDE 完成初始化后，proxy 在每个 workspace root 写入 `.dart_tool/dana-ide-bridge.json`。
`dana` 找到它，用里面的 token 连接，向 IDE 的 analyzer 获取它已经算好的诊断。

## 配置

```sh
dart pub global activate dart_analysis_server_proxy
dana_analysis_server analyzer-path --output <目录>/dana_analysis_server_proxy.dill
```

`analyzer-path` 用当前 Dart SDK 编译 proxy，写到你指定的位置，并打印要添加的配置。把
`dart.analyzerPath` 写到下面其中一处，然后重启 analyzer：

| 范围 | 配置位置 | 相对路径起点 | 生效范围 |
| ---- | -------- | ------------ | -------- |
| 单项目 | 项目的 `.vscode/settings.json`（可入库） | 项目目录 | 把这个项目作为单个 folder 打开的窗口；多根窗口里不生效 |
| 多项目 | `.code-workspace` 文件的 `settings` | workspace 文件所在目录 | 通过这个文件打开的窗口，含其中所有 folder |
| 全局 | 用户设置，绝对路径或 `~/` | — | 所有窗口 |

单项目、多项目的配置会覆盖全局配置。workspace 文件放在项目目录旁边时的写法：

```jsonc
// ~/work/app.code-workspace
{
  "folders": [{ "path": "app" }, { "path": "../shared_lib" }],
  "settings": {
    "dart.analyzerPath": "app/tool/dana/dana_analysis_server_proxy.dill"
  }
}
```

需要知道：

- `.dill` 文件 只能在编译它的 Dart SDK 上加载，升级 SDK 后要重新执行 `analyzer-path`。文件缺失
  或加载失败时，Dart-Code 会报错，analyzer 起不来。
- 团队统一使用同一个 SDK（例如用 FVM）时，可以把 `.dill` 文件（约 8 MB）和单项目配置一起入库，
  升级 SDK 的同一个改动里重新生成。个人使用可以放在 `.dart_tool/dana/`，不会进 git，但
  `flutter clean` 会删掉它。
- 确认是否生效：analyzer 进程运行的是你的 `.dill`（带 `--lsp`），并且存在
  `.dart_tool/dana-ide-bridge.json`。没走 proxy 时进程是 `dart language-server --protocol=lsp`，
  也没有 bridge 文件。
- 回退：删除这项配置并重启 analyzer。

## 与 dana 一起使用

```sh
# 必须复用 IDE 的 analyzer（没有 bridge 时退出码 69）。
dana check --root path/to/project --mode full --reuse-ide require
dana check --root path/to/project --files lib/main.dart --reuse-ide require
```

使用默认的 `--reuse-ide auto` 时，`dana` 有 bridge 就用 bridge，没有就用自己的 session。

- 结果反映的是 IDE 当前的状态，包括未保存的编辑。门禁必须只检查磁盘内容时，用
  `--reuse-ide never`。
- IDE 刚启动或 reload 时插件可能还在加载，一段时间内不推送任何诊断，此时即使 settled 也可能
  缺少插件 lint。如果依赖插件 lint，可以放一个必定产生一条插件诊断的文件，缺失时重试。

## Bridge

- 支持 `status`、对指定文件或目录的 `check`、对整个 root 的 `fullCheck`，都从 IDE 的
  analyzer 已发布的诊断里取结果，不会触发重新分析。
- `fullCheck` 先把上次空闲之后改过的 Dart 文件通知 analyzer，等这轮分析结束，再等到 2 秒内
  没有新诊断（插件在 server 空闲之后才推送）。最后这段等待有上限，默认 180 秒，可按请求用
  `settleLimitSeconds`（1–3600）指定；到达上限时返回 `settled: false`。
- 每个 workspace root 一个 endpoint，各有自己的 token，结果只限于这个 root。bridge 只监听
  本地回环，不能关闭 analyzer，也不会改动 IDE 中未保存的内容。

## 环境变量

| 变量 | 默认值 | 作用 |
| ---- | ------ | ---- |
| `DANA_PROXY_LOG` | 未设置 | 把 proxy 的诊断信息（upstream 启动失败和退出、upstream 的 stderr、LSP 帧错误）另外追加到这个文件；这些信息始终会写到 stderr |
| `DANA_ANALYSIS_TIMEOUT_SECONDS` | 1800 | upstream 请求和 `fullCheck` 等待的上限；`0` 表示不限 |
| `DANA_DART_EXECUTABLE` | 自动发现 | proxy 以原生可执行文件运行时，用来启动 upstream analyzer 的 Dart 运行时；未设置时依次查找 `DART_SDK`、`FLUTTER_ROOT` 和 `PATH` |

## 命令

执行 `dana_analysis_server --help` 或 `dana_analysis_server help <命令>`。不是它自身命令的
参数都会原样转发给 analyzer；proxy 自己的参数 `--upstream-executable <dart>`
放在 `--` 之前，例如 `dana_analysis_server --upstream-executable <dart> -- --lsp`。

## 切换 SDK 与卸载

切换 SDK 后，用对应 SDK 重新执行 `analyzer-path`，并重启 IDE analyzer。

卸载时，先删除对应作用域的 `dart.analyzerPath` 并重启 analyzer，再执行
`dart pub global deactivate dart_analysis_server_proxy`。
