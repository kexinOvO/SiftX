# SiftX

面向 Safari 的原生网页媒体发现与下载工具。Safari 负责发现和选择；SiftX.app 负责下载、整理媒体、历史与文件管理。

**SiftX processes media information locally.** 无服务器、分析 SDK、广告或用户追踪。只连接用户选择的媒体来源。

## 启动

当前交付的开发签名 Release 应用为 **`Build/SiftX.app`**，可直接打开。重复构建交付版可运行 `sh Scripts/build_release.sh`，输出保持在同一路径，避免 Safari 登记多个相同的开发副本。

使用 Xcode 打开 `SiftX.xcodeproj`，选择 **SiftX** scheme，运行。工程包含主应用、Safari App Extension 和 Safari Web Extension；共享逻辑是本地 Swift Package `SiftXCore`。

Xcode 的 Debug 和 Release 也统一输出到 `Build/SiftX.app`；不要同时构建两个配置。旧生成副本已归档成 ZIP。macOS 14+、Apple silicon；本机验证环境为 macOS 27.0 / Xcode 27.0 / Swift 6.4。未验证旧系统实机与 Intel Mac。

首次打开后，在 **Safari → 设置 → 扩展** 启用：

1. **SiftX Safari Extension**：工具栏图标与原生 SwiftUI 媒体菜单。
2. **SiftX Media Probe**：后台自动发现网页媒体，需要保持启用并允许访问所需网站。

当前本地开发构建若被 Safari 拒绝运行，在 Safari → 设置 → 开发者临时开启“允许未签名的扩展”，由用户完成系统身份验证。此开关在 Safari 退出后重置；常规分发需要相应发布签名。[Apple 开发运行说明](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension)

两个扩展保持启用，工具栏只需保留 **SiftX 主按钮（Safari Extension）**；数字角标表示当前网页可下载的选项数。按住 ⌘ 将 Media Probe 图标拖出工具栏，或通过 Safari → 显示 → 自定工具栏移除该图标，探针仍会在后台发现媒体。[Safari 工具栏自定说明](https://support.apple.com/guide/safari/ibrw1012/mac)

为这两个扩展允许访问所需网站，刷新网页并播放媒体，点击 SiftX，选择清晰度右侧的下载箭头。在主 App 的“下载管理”看进度，完成后打开文件或在 Finder 中显示；默认保存到系统下载文件夹。没有选项时可点媒体菜单右上角刷新；扩展更新后刷新网页；媒体菜单的刷新会重新分析播放清单。只有 `blob:` 内存地址时无法直接下载。未启用时，主应用的 Safari 设置页会显示状态。系统要求的首次扩展授权需要用户确认。

下载前可点击视频左侧的缩略图，打开预览确认内容、画质和声音。预览画面铺满媒体菜单，只保留“返回”和“下载”两个悬浮控件。播放器提供播放/暂停、进度和音量控制；确认后可直接点“下载”，或点“返回”回到媒体列表。音频不走预览层：把指针放到列表行的波形图标上会显示播放按钮，点击即开始播放，再次点击暂停；悬停其他音频行点击可切换播放。无法播放时视频预览提供重试入口。

在 **SiftX → 设置 → Safari → 插件图标** 中，可以选择当前 PNG，或 `arrow.down`、`arrowshape.down.fill`、`arrowshape.down.circle`、`chevron.down.circle`、`arrow.down.circle`、`arrowtriangle.down.circle`。选择自动保存，并更新 Safari 工具栏的 SiftX 主按钮；默认使用当前 PNG。[Safari 图标更新 API](https://developer.apple.com/documentation/safariservices/sfsafaritoolbaritem/setimage(_:))

在 **SiftX → 设置 → Safari → 工具栏** 中，可用“显示下载数量红点”开关控制工具栏的数字角标，默认开启，选择自动保存。

也可以在应用中使用 **⌘N** 添加 YouTube、MP4、音频、HLS 或 DASH 链接。默认保存到系统下载文件夹；在设置中可选择其他目录、设置并发数、通知、外观和开机启动。

在 **SiftX → 设置 → 通用 → 退出** 中，可以选择关闭最后一个窗口时退出软件，或让 SiftX 继续运行在菜单栏。选择退出至托盘时会保留菜单栏入口。在 **SiftX → 设置 → 通用 → 图标** 中，可以隐藏 Dock 栏图标或菜单栏图标（两者不能同时隐藏）；退出至托盘时不能隐藏菜单栏图标。隐藏 Dock 图标后，SiftX 以菜单栏应用方式运行；菜单栏图标为 SiftX logo 的黑色剪影（模板图像，深色菜单栏自动反白），菜单内提供任务计数、暂停/继续全部、打开主窗口、设置与退出。

## YouTube 离线学习

在 Safari 打开单个 YouTube 视频，点击 SiftX，选择“自动清晰度”下载带声音的视频，或选择“仅音频”。应用会读取可用的兼容画质并加入现有下载队列，不需要先播放视频。在 SiftX 按 **⌘N** 粘贴视频链接，点击“读取媒体”，可以选择具体清晰度或 M4A 音频。

支持 `youtube.com/watch`、`youtu.be`、Shorts 和嵌入视频链接；视频链接里的播放列表参数仅用于识别当前视频，不会批量下载整个播放列表。完成的视频保存为 MP4，音频为 M4A，可从“下载管理”打开或在 Finder 定位，离线反复学习。暂停、继续、取消和重试沿用现有队列。

应用随包携带固定版本的 [yt-dlp](https://github.com/yt-dlp/yt-dlp) 和 [QuickJS-NG](https://github.com/quickjs-ng/quickjs)，无需安装 Python 或命令行工具。下载时重新解析视频页，避免保存过期的媒体地址。直播需结束并处理完成后再下载；登录、年龄验证、会员、地区限制或网站临时访问限制会给出说明。

## 已实现

- 直接视频、音频、HLS 多清晰度与独立音轨、常见静态 DASH。
- 普通 AES-128 HLS：自动读取 HTTP(S) 密钥、流式解密和合并，支持默认/显式 IV、密钥轮换、加密初始化段及独立音轨；密钥只在本次下载的内存中缓存。
- DOM / Performance / webRequest 观察，过滤媒体分片，限定缓存大小、去重、质量聚合。
- 每个文档与 SPA 页面独立 UUID；两套扩展通过文档上下文握手关联，查询原生当前页面，不用 URL 或两套 Tab ID 直接匹配。
- 原生 Safari SwiftUI popover、可下载文件、无法下载原因、全部/视频/音频筛选、刷新和打开 SiftX。
- 下载前预览：视频缩略图、原生播放器（返回/下载悬浮控件），保留所选 HLS 清晰度和独立音轨，支持常见带初始化段与时间信息的 fMP4 DASH；音频在列表行内悬停播放/暂停试听。
- 持久下载队列、并发限制、进度/速度/已下载量、已知大小的剩余时间估计。
- 暂停、恢复、取消、重试、批量暂停/继续、删除与清除完成任务。
- 直接媒体流式写盘，验证服务器 Range 与实体版本；HLS/DASH 分片断点保留、本地合并。
- 历史持久化、重下载、复制来源、打开文件、Finder 定位、文件删除/缺失处理。
- 安全文件名、独占原子提交与同名数字后缀，保留已有文件。
- 文件夹及文件 security-scoped bookmarks；切换默认目录后保留历史文件访问授权。
- 重启后将中断任务恢复为暂停；下一次启动读取 Safari 已提交的持久请求。
- macOS 通知、菜单栏入口、首次引导、原生设置、系统/浅色/深色外观。

## 工程结构

```
App/                     SwiftUI 窗口、设置、下载引擎、文件处理
SafariExtension/         Safari App Extension、SwiftUI popover、页面握手
MediaProbe/              Web Extension JS 及 native 消息边界
Sources/SiftXCore/       模型、HLS/DASH、网络安全、SQLite WAL
Tests/SiftXCoreTests/    解析、聚合、数据库与输入校验
Tests/DownloadTests/    实际 HTTP 下载、恢复、合并与历史回归
Tests/MediaPreviewTests/ 原生播放、音轨、预览传输与清理回归
Tests/ProbeTests/       JS 过滤、双扩展页面会话及点击转发模拟
Tests/ConfigurationTests/ Safari 配置契约回归
Scripts/                 工程生成、媒体工具构建、本地测试站点
Config/                  App entitlements、Info.plist、回调兼容桥
docs/.codex/             可继续开发的项目上下文
ThirdParty/              媒体处理器对应源码
```

## 构建与测试

```sh
python3 Scripts/generate_project.py
xcodebuild -project SiftX.xcodeproj -scheme SiftX -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath Build/DerivedData build
swift test
node --test Tests/ProbeTests/*.test.cjs
python3 Tests/ConfigurationTests/test_safari_configuration.py
```

真实下载测试使用本机生成的 12 秒 H.264/AAC 视频，不依赖公共网站或私人账号：

```sh
# 生成测试资源需要完整 FFmpeg；正常使用应用不需要额外安装。
python3 Scripts/make_fixtures.py
python3 Scripts/fixture_server.py
# 在另一个终端运行：
xcodebuild -project SiftX.xcodeproj -scheme SiftX \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath Build/DerivedData -parallel-testing-enabled NO \
  -only-testing:SiftXDownloadTests test
```

Safari 验证入口为 `http://127.0.0.1:18765/`。测试状态与人工步骤见 [VERIFICATION.md](VERIFICATION.md)。

本地测试站点运行后，可验证 AVPlayer 的实际解码、独立音轨、加密 HLS、DASH、进度跳转与预览传输：

```sh
SIFTX_PREVIEW_FIXTURE_BASE_URL=http://127.0.0.1:18765 swift test --filter MediaPreviewTests
```

未设置测试站点地址时，预览集成测试会跳过。YouTube 预览使用网页播放器；网站禁止嵌入或媒体格式不受系统播放器支持时，可转到原网页确认。

## 签名与共享数据

三个 targets 的 App Group 一致：`$(DEVELOPMENT_TEAM).com.siftx.shared`。`SiftXAppGroupIdentifier` Info.plist 键向共享模块提供实际展开值。macOS 的团队前缀 App Group 不需要单独注册 group ID；另一团队构建时需要为所有 targets 使用自己的签名团队，并更新生成脚本里的 `DEVELOPMENT_TEAM`。没有可用的开发证书时可以进行无签名编译检查，但这不能替代 Safari 的签名运行验证。[Apple App Groups 说明](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.application-groups)

持久化采用共享容器内 `SiftX/Shared.sqlite`，SQLite WAL、忙等待和短事务保障多进程访问。页面候选最多 100 个、页面会话最多 200 个、两小时未更新即清理；原始分片请求不写数据库。下载分片位于共享容器 `SiftX/Transfers`，取消、删除、完成及启动清理会回收临时文件。持久候选不保存大规模分片计划，下载时重新解析。

Safari 27 在当前系统上曾把带主线程标注的状态回调从 XPC 后台队列返回。`SafariStateBridge.m` 在进入 Swift 前明确切回主线程，防止 Swift 6 运行时隔离检查导致启动崩溃。其他主要逻辑保持 Swift / actor / async-await。

## 媒体处理依赖

随 App 携带约 3.2 MB 的精简 **FFmpeg 7.1.1** 独立进程，仅启用本地 `file,pipe` 协议及需要的解复用/复用功能。下载由原生 URLSession 执行；处理器只读取已下载的本地媒体，通常使用 stream copy。没有网络协议或 DRM 解密组件。Swift 包除 Apple 框架、SQLite 外没有第三方依赖。

源码：`ThirdParty/ffmpeg-7.1.1.tar.xz`，来自 [FFmpeg 官方发行目录](https://ffmpeg.org/releases/)。构建命令在 `Scripts/build_media_tool.sh`；许可证在 `App/Resources/FFmpeg-LICENSE.txt`。详见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 当前边界

- 支持普通 AES-128 HLS（`KEYFORMAT=identity`），按 [HLS 播放规范](https://datatracker.ietf.org/doc/html/rfc8216#section-4.3.2.4) 读取服务器提供的 16 字节二进制密钥。FairPlay、Widevine、SAMPLE-AES、DASH ContentProtection 和网页 EME 保护仍不可下载；加密 I-frame 专用列表及非 HTTP(S) 密钥暂不支持。
- 不录制直播；需要已结束的 HLS 或静态 DASH。DASH 支持单 Period 的 SegmentTemplate（含 Timeline）、SegmentList、直接 BaseURL；不支持依赖 SIDX 的 SegmentBase、多 Period、特殊播放器协议。
- 浏览器 `blob:` 地址自身不可下载；能发现底层普通媒体 URL 时使用底层资源，否则显示说明。
- 不复制浏览器 Cookie/Authorization。必须依赖登录 Cookie、自定义授权签名、浏览器专有握手的来源可能返回 403；会提示访问限制，不能保证每个网站可用。
- 私人浏览页面不写入共享媒体状态。YouTube 使用专用解析组件，普通媒体仍使用原生发现与下载。
- 媒体源失效后重试可能仍失败。转码、专业编辑、云同步不在范围内。
- 此为本机开发签名构建；公开分发还需 Developer ID/商店签名、发布测试与公证。当前应用运行不依赖额外安装 FFmpeg。
