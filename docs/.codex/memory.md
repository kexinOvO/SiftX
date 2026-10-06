# 维护记录

Last reviewed: 2026-10-06

- Safari → 工具栏的“显示下载数量红点”通过可选 `toolbarBadgeVisibleFlag` 持久化，旧设置默认开启。图标与红点选择变化均触发原有工具栏刷新消息。关闭时立即返回空角标、清空窗口缓存并废弃旧请求，异步页面回复后需重读偏好。回归在 `CoreTests` 的旧设置兼容/跨 Store 保存测试及 `ToolbarBadgeTests` 的关闭/重新开启/迟到查询测试。

- 已完成详情内的预览只读取下载完成的本地文件，沿用 `DownloadFileLease`，不要复用 Safari 的网络代理或 YouTube 网页播放器。播放器与 security-scoped 文件授权必须同寿命；视频使用原生播放控件，音频使用位于表单上方的单行播放按钮和进度滑条。切换记录/离开详情时移除周期时间与状态观察，暂停并清空播放项，再释放授权。实现：`App/Views/DownloadDetail.swift`。

- “退出软件行为”保存在 `AppSettings.exitBehaviorRawValue`；缺失或未知值回退到“关闭软件”。`SiftXApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed` 控制关掉最后一个窗口后退出进程或保留到菜单栏。选择“退出至托盘”时，菜单栏图标必须可见，设置页会显示并锁定该入口；重开菜单项通过主窗口内容注入的 `openWindow(id: "main")` 与弱窗口引用恢复窗口，不依赖会随导航变化的标题。

- 主窗口通过单一“下载管理”入口展示全部持久下载记录，不按完成状态分栏；搜索按媒体标题或网页名称筛选，列表按创建时间倒序排列。任务行和详情依据各自状态提供操作。筛选与导航定义在 `App/Views/MainView.swift`。

- Safari 媒体列表的下载按钮使用粗体 `arrow.down`，macOS 26.1+ 声明透明 Liquid Glass 样式 `.glass(.clear)`，macOS 26.0 使用 `.glass`，更早系统回退 `.bordered`；共用 `.circle` 形状、`.small` 控件尺寸和 `.title3` 基础字号。按钮背景按 1.2 倍缩放，箭头通过内层补偿最终呈现为基础尺寸的 0.7 倍。`MediaChoiceRow` 垂直居中，提交后显示原尺寸常规字重勾号并禁用按钮。

- 下载前预览保留 195pt 媒体列表，视频使用可点击的 48×32pt 缩略图，音频保留波形并可试听；播放器展开到 560×440pt，返回保留筛选。关闭 popover、返回或文档上下文变化必须清除播放器、观察、准备任务和回环代理。
- 预览通过 `MediaPreviewProxy` 保留 Referer、Range、HLS 独立音轨与 AES-128 资源，不依赖非公开 AVURLAsset header 选项。监听仅绑定 127.0.0.1，注册 URL 含随机作用域；不持久保存预览媒体或密钥。同一密钥 URL 的不同 EXT-X-KEY 声明须使用独立代理路径，防止播放器复用过期密钥。
- HLS 的 `loadTracks(.audio)` 可能返回空数组；确认声音要同时读取 audible media selection group。DASH 预览仅在有初始化段与真实分片时长时转换 fMP4→HLS；`DASHRepresentation` 新增元数据不得改变下载使用的既有 segments。
- 预览 XCTest 位于 `Tests/MediaPreviewTests`，设置 `SIFTX_PREVIEW_FIXTURE_BASE_URL` 并启动当前 fixture server 才运行实际播放器检查，未设置时跳过。2026-10-06 五项通过，Safari MP4/MP3/加密 HLS 独立音轨与错误反馈实机通过，完整证据见 VERIFICATION.md。

- YouTube 下载入口使用 `MediaTransport.youtube`，支持规范化 watch/youtu.be/Shorts/embed 单视频 URL；不把浏览器 blob 或过期 googlevideo 地址当作持久下载来源。Safari 可在播放前提供自动视频与仅音频动作，具体画质在主 App 的 ⌘N 中读取。
- YouTube 用随包 yt-dlp 2026.08.19 + QuickJS-NG 0.17.0。必须保留 `YouTubeTools/_internal` 目录，并使用 onedir 发行包；onefile 版在沙盒内会因 System V semaphore 被拒绝。ZIP 的 Python.framework 链接需由 `normalize_youtube_tools.py` 恢复，所有原生库与 framework 在复制后签名，只有两个 CLI 持有 sandbox-inheritance entitlements。版本、摘要和许可证见 THIRD_PARTY.md。
- Xcode 命令构建应显式指定 `CONFIGURATION_BUILD_DIR` 到固定 `Build` 路径，保障本地 package 与应用引用同一版 Swift 模块。仅在应用 target 固定输出目录时，默认 package 输出可能被 `Build/SiftXCore.swiftmodule` 的旧副本遮蔽。
- Release 构建前若留下 Debug 的 `.debug.dylib` / `__preview.dylib`，`prepare_release_products.py` 只移除三份生成包再重建。不要对整个 `Build` 使用 `xcodebuild clean` 或将其标记为可清理目录：其中还存有验证日志与归档。
- YouTube 功能的沙盒实机已通过：⌘N 读取截图视频并完成 1080p MP4 下载，ffprobe 检查为 H.264 1920×1080 + AAC、193.422 秒。自动化 5 项 YouTube 核心与 3 项下载专项、共 19 项下载回归通过；完整证据见 VERIFICATION.md。

- App Group 使用所有 targets 一致的团队前缀值，通过 Info.plist 传给 SiftXCore。更换签名团队时更新 `Scripts/generate_project.py` 的团队配置并重新生成工程。
- Safari 的两个扩展体系通过文档 token 和当前 SFSafariPage nonce 查询关联。相同 URL 的 Tab 必须保持独立；不要把两个体系的 Tab ID 互相替代。
- 共享数据只使用 SharedStore 的 SQLite 边界。先持久任务再 ack 请求，稳定请求 UUID 保障进程中断后的幂等接管。
- 解析所得 MediaPlan 不进入持久候选/历史；重新下载或恢复时重新解析。大规模 raw 分片请求不能变成用户候选或浏览历史。
- macOS sandbox 的默认 Downloads 路径可能是指向用户下载目录的符号链接。目录检查需跟随链接，随后实际独占写入探测；resourceValues 的 isDirectory 不能单独决定该路径能否下载。回归：`testDownloadFolderFollowsSandboxStyleDownloadsSymlink`。
- 完成文件持有自己的 fileBookmark。当前默认目录授权不能替代旧历史文件授权。缺失文件可移除记录；权限失败需要保留记录并提示。回归：`testHistoryFileAccessSurvivesFolderChangeAndMissingFileRemoval`。
- Range 恢复需要验证实体身份及 Content-Range。服务器返回完整 200 时重置临时文件；无 validator 时重下。不要将新版媒体尾部追加到旧版部分文件。
- worker generation 保护旧异步回调；立即暂停/继续和取消/重试必须等旧 worker 关闭文件后再启动下一次。
- 内置 FFmpeg 只处理已下载的本地文件，不传媒体 URL/manifest，不启用网络或加密解密。许可证和对应源码随仓库保留。
- Safari 状态/偏好设置 API 的本机后台 XPC 回调使用 `App/SafariStateBridge.m` 明确切回主线程，再进入 Swift 6 main actor。
- XCTest 临时 Store 改为 teardown 阶段、工作任务退出后清理，最终 12 项集成日志无 vnode-unlinked 诊断。不要在测试函数仍持有 SharedStore 时删除数据库目录。
- 当前交付路径是 `Build/SiftX.app`；构建脚本及工程所有 targets 的 Debug/Release 均固定输出在此路径，避免 Xcode 再生成第二套 App。不要同时构建两个配置。多个相同 Bundle ID 的开发 App 会导致 Safari 重复登记，验收时应只保留一套实际 App，旧生成副本归档为 ZIP。
- Release 沙盒 GUI 已完成 MP4、MP3、HLS 分离音轨与静态 DASH 下载；HLS 经 Finder 定位并由 macOS 快速查看实际播放。详细结果见 VERIFICATION.md。
- JS 模拟、解析测试和直接 HTTP 下载不能作为 Safari 实机链路验收。启用两个扩展及站点访问权限后，单独记录 popup、多 Tab、SPA 和 Safari 重启的实际结果。

- Safari 原生功能键必须直接置于 NSExtension，不能放在 NSExtensionAttributes；错误层级会使按钮没有 Popover 动作且脚本不注入。配置回归位于 Tests/ConfigurationTests/test_safari_configuration.py。
- Safari 工具栏日常只需显示原生 SiftX 主按钮；通过自定工具栏隐藏 Media Probe 图标可保留后台发现。2026-10-06 实机确认隐藏后两扩展仍启用，主按钮显示本地 MP4 的质量、分辨率和大小。保持两扩展启用及所需网站授权；图标可见性由 Safari 工具栏设置管理。
- 2026-10-06 本机 Safari 验证：移除 Media Probe 的 manifest `browser_action` 并重新构建、关闭再启用该扩展后，Safari 仍生成工具栏按钮，标题改用扩展名称。该配置不能实现永久隐藏；保留现有点击转发配置，使用 Safari 自定工具栏管理图标可见性。
- Safari 原生工具栏 Image 使用完整 `ToolbarSymbol.png` 文件名，资源为用户提供的透明 S 标志 PNG（原始尺寸 897×850）。工程生成器将该 PNG 纳入扩展资源构建阶段。
- 插件图标选项控制原生 Safari 主按钮。`PluginIcon` 定义当前 PNG 与六种 SF Symbols；`AppSettings.pluginIcon` 为可选原始字符串，保证旧设置解码并保留其他偏好，未知图标回退 PNG。主 App 与扩展共享同一 PNG 资源供设置预览；工程中保持单一文件引用的分组归属。兼容与跨 Store 保存回归见 `CoreTests.testPluginIconReadsExistingSettingsAndFallsBackForUnknownChoice`、`testPluginIconPersistsAcrossStoreConnectionsAndSymbolsExist`。
- `validateToolbarItem` 不能每次先回传空角标再异步设置数量：这会使重复扫描时红点闪烁。`ToolbarBadgeState` 按窗口缓存可见文本、以请求 UUID 拒绝迟到查询，仅数量变化时调用 `setBadgeText`。回归在 `Tests/SafariExtensionStateTests/ToolbarBadgeTests.swift`。
- background.js 按成功发布的观察快照去重，并保留每分钟一次 native 存储心跳；相同心跳不触发工具栏更新，native 数量变化仍触发，失败不会缓存成功状态。HLS/DASH 再分析时不要用临时保护占位覆盖已有候选。JS 回归在 `Tests/ProbeTests/session.test.cjs`。
- 探针按钮经顶层 DOM 事件转发到原生 PageContextResolver，使用消息来源页面的 containingTab/window；无原生桥时回退到打开主 App。不要为探针添加 HTML popup。
- 本地开发构建的 Safari unsigned 开关在退出 Safari 后重置，需要用户确认并完成系统身份验证；本机没有 Developer ID 签名身份，当前交付版本为 1.0 build 3。
- Safari 本机基础链路现已实际通过：两按钮打开原生菜单，MP4 发现质量信息并提交到主 App，完成文件与源 SHA-256 一致。验证结果在 VERIFICATION.md。公共必应 YouTube 内嵌页面仅发现内存媒体，显示解释而非可下载结果。
- MainView 的添加/批量操作与 searchable 放在整个 NavigationSplitView 上，操作使用 navigation placement，位于下载列表上方；在 980×650 实机窗口验证分栏边界留白、添加 sheet、批量菜单和搜索筛选。保持系统原生工具栏样式。

- 应用图标采用 `App/Resources/AppIcon.icon/` 的 Icon Composer 分层资源，来自用户的 `siftX.icon` 原文件。Xcode 用 `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` 编译系统图标外观到 `Assets.car` 并生成兼容 ICNS，支持 macOS 系统设置 → 外观 → 图标与小组件样式。工程生成器将 `.icon` 作为整体资源引用。原尺寸默认 PNG 另保存在 `Scripts/Assets/AppIcon.iconset/`，六种外观的 1024px 导出参考保存在 `Scripts/Assets/AppIconPreviews/`。

- Safari 下载面板以 `protection == nil` 过滤文件列表，其他候选只提供去重后的原因；正在分析的候选显示加载状态。类型筛选使用 `MediaCandidate.kind`，带音轨的视频属于视频；文件和受限原因按相同类型筛选，页面级错误始终可见。面板每次打开默认全部，刷新保留选择。顶部固定类型筛选，底部保留刷新及打开 App。SwiftUI 内容高度测量同步到 Safari preferredContentSize，长内容在 336pt 内容区滚动，总高最多 429pt。

- Safari 下载面板统一宽度为 195pt，由 `PopoverLayout.width` 同时控制 preferredContentSize 和 SwiftUI 根视图。条目用分辨率作为主行，协议/格式与时长作为次行；缺少尺寸时回退已有清晰度或媒体类型，缺少时长时不虚构。紧凑布局采用 12pt 横向留白、8pt 行间隔，描述可换行。2026-10-06 Release 构建、签名验证与七种状态的浅色/深色原生预览通过；Safari 重新加载后的实际显示仍需实机确认。

- 普通 AES-128 HLS 的描述只保存 keyURL/IV/keyID，不保存密钥字节；keyID 由播放清单 URL 和 EXT-X-KEY 次序决定，包含音轨及同 URL 新作用域。EXT-X-SESSION-KEY 不代替子播放清单的 EXT-X-KEY；初始化段加密需要显式 IV，初始化段不推进媒体序号。
- 解密读取新 FileHandle 的实际长度，不依赖 NSURL 缓存的 resourceValues 文件大小；完整验证 PKCS#7 的所有填充字节，失败不发布 .chunk。暂停保留密文 .part 与已完成的明文 .chunk；计划包含加密描述，指纹变化时重建分片目录。回归见 HLSEncryptionTests、EncryptedHLSTests。
- 16 项下载回归、35 项核心、3 项角标、35 项 JS 和 2 项配置测试通过；七种 AES-128 输出与原始分片 SHA-256 相同，均为 12.032 秒 H.264/AAC，完整解码无错误。记录在 Build/aes-*-tests.log 与 Build/aes-output-verification.json。用户于 2026-10-06 确认原网站可以下载；网站兼容性仍需逐站验证。
- 用户刷新需要强制 native 清理分析缓存，而普通重复观察继续去重。页面宣布仅在后台确认相同 sessionID 后缓存成功；后台丢失登记时，resources 先重新登记再补发。JS 回归覆盖强制刷新、错误会话/iframe 拒绝和登记恢复。
