# 项目

Last reviewed: 2026-10-06

SiftX 是面向 Safari 的原生媒体发现与下载工具。Safari 展示整理后的质量选项并提供下载前预览，主 App 独立下载、合并和保存历史。全部媒体信息本地处理，没有远程服务端或追踪 SDK。

## 栈与入口

- macOS 14+、Swift 6、SwiftUI、SafariServices、AVFoundation/AVKit、Network、Foundation URLSession、SQLite WAL。
- Xcode 工程 `SiftX.xcodeproj`，scheme `SiftX`；主入口 `App/SiftXApp.swift`。
- Safari App Extension：`SafariExtension/SafariExtensionHandler.swift`。
- Web Extension：`MediaProbe/Resources/manifest.json`、`background.js`、`content.js`，native 入口 `NativeProbeHandler.swift`。
- 本地 package `SiftXCore`：`Package.swift`、`Sources/SiftXCore/`。
- 独立本地媒体处理器：`App/Resources/ffmpeg`。版本、构建和许可证见 [THIRD_PARTY.md](../../THIRD_PARTY.md)。

当前工程配置与内置处理器为 Apple silicon。本机验证环境为 macOS 27 / Xcode 27；其他系统与 Intel 需另验。

## 仓库地图

| 路径 | 职责 |
| --- | --- |
| `App/Views`, `App/Settings` | 主窗口、下载记录、添加 URL、设置、引导和菜单栏 |
| `App/Downloads` | 下载队列、HTTP 传输、分片、处理器、文件授权与提交 |
| `SafariExtension/` | 原生工具栏、SwiftUI popover、当前页面上下文查询 |
| `SafariExtension/Preview`, `PreviewNetworking` | 缩略图、原生/网页播放器、临时回环预览传输 |
| `MediaProbe/` | DOM/网络发现与受限 native 消息边界 |
| `Sources/SiftXCore/` | 共享模型、解析、安全输入、SQLite 数据层 |
| `Tests/` | Swift 核心、实际 HTTP 下载、JS 页面会话测试 |
| `Scripts/` | 工程/图标生成、FFmpeg 构建、本地媒体测试站点 |
| `Config/` | 主 App Info.plist、entitlements、ObjC 桥头文件 |

## 命令

固定路径的 Release 交付构建：`sh Scripts/build_release.sh` → `Build/SiftX.app`。验收时避免同时保留多个相同 Bundle ID 的已登记 App；旧 Debug/Release 生成副本已归档为 ZIP。

```sh
python3 Scripts/generate_project.py
xcodebuild -project SiftX.xcodeproj -scheme SiftX -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath Build/DerivedData build
swift test
node --test Tests/ProbeTests/*.test.cjs
```

下载集成测试先运行 `python3 Scripts/make_fixtures.py` 和 `python3 Scripts/fixture_server.py`，再执行 README 中的 `xcodebuild ... -only-testing:SiftXDownloadTests test`。生成资源需要完整 FFmpeg；运行已构建的 App 使用内置处理器。

预览集成测试使用同一测试站点：`SIFTX_PREVIEW_FIXTURE_BASE_URL=http://127.0.0.1:18765 swift test --filter MediaPreviewTests`，未设置站点地址时跳过。

三个 targets 必须使用同一开发签名团队及 App Group。首次 Safari 扩展启用和网站授权由用户完成。最新通过项和待验收项见 [VERIFICATION.md](../../VERIFICATION.md)。
