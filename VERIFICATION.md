# 验证记录

## 单行音频播放控件（2026-10-06）

- 已完成音频详情顶部用 SwiftUI 播放/暂停按钮和 Slider 呈现为一行，按钮与进度有可访问名称。控件由本地 AVPlayer 的时长、播放状态和周期时间观察同步；结束通知记录终点，再次点击从起点播放。切换记录时移除观察并释放文件授权。
- 按用户要求由 `gpt-6-luna`、medium 做代码审阅和实机检查。最终 Release 增量构建及签名检查通过，日志 `Build/completed-audio-strip-final-build.log`；没有执行全局 clean 或更改用户下载记录、媒体文件、设置。
- 3.1 MB Moonride M4A 的单行布局、初始暂停、播放进度推进及拖动跳转至约 68 秒已实机验证。播放中切换视频后新视频暂停，返回 M4A 时暂停且进度为 0。
- M4A 播放进度从 4.25 秒增至 8.75 秒，点击暂停后读数为约 11.86 秒，再次读取保持不变。最终界面留在该音频详情，播放按钮显示且进度为 0。
- 97 KB MP3 自然结束后恢复播放图标，再次点击从进度 0 开始，重播已实机验证。

## 已完成详情内本地媒体预览（2026-10-06）

- `App/Views/DownloadDetail.swift` 在已完成记录顶部新增视频/音频预览，使用 AVPlayerView 原生控件和下载文件的 security-scoped bookmark；切换记录/离开详情时暂停、清空播放项并释放授权。加载失败、缺失文件、播放中断和超时提供提示与重试。
- 按用户要求由 `gpt-6-luna`、medium 执行检查。代码审阅未发现明显生命周期问题；Release 编译通过，日志 `Build/completed-preview-build.log` 含 `BUILD SUCCEEDED`。
- 首轮交付脚本的严格递归签名检查发现外层资源 seal 早于嵌套 YouTubeTools 的重新签名。保留 identifier、entitlements、flags、runtime，仅用本次 Apple Development 身份重新签署外层生成产物后，`codesign --verify --deep --strict --verbose=2 Build/SiftX.app` 通过，日志 `Build/completed-preview-signature.log`；固定产物正常重启。
- 现有本地测试 MP4 初始暂停（00:00）且画面可见，点击播放后画面随时间变化，暂停有效；带名称的播放/暂停、时间轴、音量/静音控件可访问。97 KB 音频的播放/暂停和跳转至约 7 秒通过实机检查。实际 3.1 MB Moonride M4A 显示 03:13、初始暂停，点击后进度推进至约 14 秒。
- 视频播放中切换到 M4A，旧视频停止，新播放器初始暂停；再回原 MP4 时暂停且进度重置为 00:00。验收结束保留视频详情可见、播放器暂停。未更改用户设置、下载记录或媒体文件。
- 没有现有缺失文件实例，缺失/授权失效、格式失败、加载超时、中途失败提示未做实机注入验证；错误处理已做代码审阅。现有 6 KB 音频显示零时长、开始后马上停止，但未触发错误，因此不将其计为坏文件反馈通过。深色外观未实测。

## 图标显隐开关 + 菜单栏 S 剪影图标（2026-10-06）

- 设置 → 通用新增「图标」区：「隐藏 Dock 栏图标」「隐藏菜单栏图标」，二者互斥（同时隐藏会弹「设置未完成」提示），持久化到 AppSettings（optional `dockIconHiddenFlag` / `menuBarIconHiddenFlag`，旧设置 JSON 向后兼容）。
- 隐藏 Dock 图标：`NSApp.setActivationPolicy(.accessory)`；菜单栏图标由 SwiftUI `MenuBarExtra` 改为 AppKit `NSStatusItem`（autosave `SiftXMenuBarItem`），原因：本机 Xcode 26 beta 工具链上 `@SceneBuilder` 的 `if` 条件触发编译器 bug（最小复现确认），且 NSStatusItem 可随时显隐。菜单内容等价旧 MenuBarView（计数、暂停/继续全部、打开主窗口、设置…、退出）；「打开 SiftX」经 `applicationShouldHandleReopen` 重建已关闭的主窗口；「设置…」走 `showSettingsWindow:`。
- 菜单栏图标改为 SiftX logo（用户提供的 333.png）的黑色剪影：Pillow 生成（alpha≥30 保留软边、裁切居中、18pt@1x + 36pt@2x），`App/Resources/MenuBarSymbol(.png/@2x.png)`，构建期经 COMBINE_HIDPI_IMAGES 合并为多分辨率 `MenuBarSymbol.tiff`；`isTemplate = true`，浅色菜单栏渲染黑色剪影、深色自动反白（实机截图确认）。
- 构建修复：`CONFIGURATION_BUILD_DIR=$(SRCROOT)/Build` 导致显式模块扫描只查 `Build/` 里过期的 `SiftXCore.swiftmodule`（干净环境下 SPM 产物在 DerivedData Products），`generate_project.py` 为全部 target 增加 `SWIFT_INCLUDE_PATHS` / `LIBRARY_SEARCH_PATHS = $(BUILD_DIR)/$(CONFIGURATION)`（注意该 Xcode 版本 BUILD_DIR 已含 Products 段，不能写 `$(BUILD_DIR)/Products/...`）。
- Debug 构建 `BUILD SUCCEEDED`；菜单栏图标、Dock 显隐、双开关互斥已实机验证；`MenuBarView.swift` 已移除（功能并入 `ApplicationModel`）。

## 动画方案回退 + 音频行内试听（2026-10-06）

- 结论：Safari popover 窗口由 Safari 远程托管，`preferredContentSize` 变更只会瞬时生效；NSAnimationContext、`window.animator().setFrame`、逐帧 Timer 插值均无法做出可靠的窗口尺寸动画（多轮实测/录屏证实）。经用户确认「维持现状」：预览覆盖层铺满 popover、窗口尺寸瞬时切换，不再尝试放大动画。
- 音频不再打开预览层：列表行波形图标悬停显示播放按钮（播放中显示暂停），点击行内播放/暂停；点击其他音频行切换播放，失败后点击重试（图标变橙色警告）。实现在 `SiftXPopover.swift` 的 `InlineAudioState` / `InlineAudioBadge`，播放复用 `MediaPreviewPlayback`，其 `objectWillChange` 经 Combine 转发到 `PopoverModel` 驱动行刷新。
- 视频/音频互斥：打开视频预览或关闭 popover 时 `stopAudio()` 停止行内播放。
- Debug 构建（正常签名）`BUILD SUCCEEDED`；行内试听交互待 Safari 实机抽查。

## 预览原地放大（2026-10-06，已回退）

- 预览交互重做：点击缩略图后不再整体替换为 560×440 的独立预览页，预览作为覆盖层铺满 popover 内容区并直接起播；窗口经 `SiftXPopoverController.apply(size:)` 平滑放大，返回时平滑缩回。
- 覆盖层自身不做位移动画（初版「缩略图→全屏」frame 动画与窗口动画互相 retarget，卡片停在中间尺寸填不满窗口，用户录屏证实，已废弃）；窗口 frame 动画是唯一运动来源，卡片跟随窗口一起变大/缩小。
- 预览画面仅保留「返回」「下载」两个悬浮圆形控件；移除原顶栏（“下载前预览”标题）、底部信息面板与“在原网页打开”入口。加载/错误/重试状态保留；AVPlayerView 延后到内容就绪后挂载，避免悬浮播放控件在加载阶段抢镜。
- Popover 尺寸切换（195pt 列表 ↔ 560×440 预览）：Safari popover 对 preferredContentSize 变更是瞬时跳变，`apply(size:)` 先记录旧窗口 frame，变更后再把窗口摆回旧 frame，用 `window.animator().setFrame` 以 0.32s easeInOut 过渡到 Safari 选定的目标 frame。初版用 NSAnimationContext 包 preferredContentSize 无效（录屏证实窗口仍瞬间跳变），已废弃。
- Debug 构建（正常 Apple Development 签名，本机证书 TeamIdentifier=P57SZ9Z7G2）`BUILD SUCCEEDED`。Safari 实机动画手感与深色模式待人工抽查。

## 下载前预览（2026-10-06）

- 视频图标替换为可点击的真实缩略图，音频保留波形并可试听。列表为 195pt，预览为 560×440pt；预览包括播放/暂停、进度、音量、画质与音轨状态，以及返回、下载、重试和原网页入口。预览不提交下载请求。
- **Safari 实机通过**：本机测试站点的 MP4、MP3、AES-128 HLS 独立音轨均打开原生预览。视频实际显示画面，音轨显示“有声音”，音频仍显示原波形图标；返回恢复紧凑列表。HTTP 200 HTML 伪媒体实际触发可读错误说明、重试和原网页入口。只操作本次创建的测试标签页，验收未点击下载。
- 5/5 预览 XCTest 通过，0 失败，日志 `Build/preview-integration-tests.log`。AVPlayer 实际解码直接 MP4、HLS 独立音轨、AES-128 HLS 独立音轨、静态 DASH；检查可读视频帧、audio tracks/audible selection、跳转至 6 秒及暂停，MP3 检查只有音轨。传输回归覆盖 Range 206、Referer、未注册路径 404、停止后的端口关闭、所选 HLS 单视频+音轨、密钥 URI 重写和相同密钥 URL 的独立声明作用域。
- Swift 核心 40/40、角标 3/3 通过，完整日志 `Build/preview-tests.log`（当时的预览 4 项也通过，新增第五项后另行完整重跑预览 target）。JS 探针 35/35、Safari 配置 2/2 通过，日志 `Build/preview-probe-tests.log`、`Build/preview-configuration-tests.log`。
- 真实 SwiftUI 视图及播放控制器的临时原生验收程序检查了缩略图、五类媒体就绪/音轨、返回后的播放器清除、列表与预览尺寸、浅色/深色布局；结果 `Build/PreviewAcceptance/result.txt`，布局图片位于同目录。AVPlayer 图层的画面以 Safari 实机观察和 XCTest 像素帧为依据。
- Release 构建成功，`Build/preview-release-build.log` 含 `BUILD SUCCEEDED`，最终交付保持 `Build/SiftX.app`。严格递归签名检查通过，日志 `Build/preview-signature.log`。
- 原生预览受系统编码支持与媒体访问权限限制；DASH 预览仅验证带初始化段和分片时间的 fMP4 示例。YouTube 非持久网页播放器已编译，公共网站内嵌播放尚未列为实机通过，网站限制时可转原网页。

## YouTube 下载（2026-10-06）

- 新增 5 项 YouTube 核心回归，覆盖 watch/youtu.be/Shorts/embed URL、跟踪/播放列表参数清理、域名仿冒、格式与音轨配对、旧数据解码、直播/DRM/错误视频 ID 拒绝；最终目标重跑 5/5 通过，日志 `Build/youtube-url-tests.log`。
- 下载 XCTest 共 19/19 通过，包含新增 3 项 YouTube 回归：持久 Safari 请求、逐轨下载、暂停后立即恢复、取消后立即重试、失效格式不阻塞队列、超时及输出大小上限。日志 `Build/youtube-download-runtime-tests.log`。该自动化测试使用本地媒体及受控解析器替身，不将公共网站波动纳入回归。
- 逐轨合并输出经 ffprobe 确认含 H.264 视频与 AAC 音频；仅音频输出为 AAC/M4A。数据在 `Build/youtube-media-verification.json`。
- 实际随包 yt-dlp/QuickJS 成功读取公开 YouTube 测试视频与用户截图中的《Moonride》；公开测试视频实际下载成功。日志 `Build/youtube-live-info.json`、`Build/youtube-moonride-info.json`、`Build/youtube-public-transfer.log`。
- **主应用沙盒实机通过**：新版 SiftX 的 ⌘N 窗口粘贴截图视频链接，显示 144p–1080p 与仅音频选项；选择 1080p 后完成，历史展示视频 + 音频、3:13、1920×1080、62.9 MB。实际文件位于系统 Downloads，ffprobe 确認 H.264 1920×1080、AAC、193.422 秒、62,879,308 字节；结果 `Build/youtube-moonride-verification.json`。
- Release 构建 `BUILD SUCCEEDED`，`codesign --verify --deep --strict Build/SiftX.app` 通过；日志 `Build/youtube-release-build.log`。随包工具采用 onedir 布局、arm64 精简、正确 framework 链接与继承沙盒签名。
- JS 探针 35/35、Safari 配置 2/2 通过，日志 `Build/youtube-probe-tests.log`、`Build/youtube-configuration-tests.log`。YouTube 页面入口的核心模型与请求接管已覆盖；Safari 新页面上的 YouTube 菜单实机检查另记，未将已有旧进程的网页缓存列为通过证据。


最后审阅：2026-10-06（Asia/Shanghai）。本机环境：Apple silicon、macOS 27.0、Xcode 27.0、Swift 6.4；工程部署目标为 macOS 14.0。

## 已取得的结果

| 项目 | 结果与依据 |
| --- | --- |
| 开发签名 Debug 构建 | 成功；`Build/signed-build.log` 包含 `BUILD SUCCEEDED`，主 App 和两个 Safari Extension targets 已生成。 |
| 原生下载集成 | Xcode XCTest 16/16 通过，0 失败，52.080 秒；`Build/aes-download-tests.log`。包含四项 AES-128 下载、密钥缓存/Referer、错误密钥与暂停恢复回归。 |
| Swift 核心逻辑 | 35/35 通过，0 失败；`Build/aes-core-tests.log`，覆盖序号 IV、显式 IV、密钥轮换、初始化段、DRM 分类、模型兼容及大分片流式解密。 |
| JS 探针与页面会话 | 35/35 通过，0 失败；`Build/aes-probe-tests.log`。新增手动强制分析、错误会话/iframe 刷新拒绝、扩展重载登记恢复；保留原有去重、角标与页面会话回归。 |
| 插件图标选择 | Release 构建及严格递归签名检查通过，日志 `Build/plugin-icon-release-build.log`。两项旧设置兼容/跨 Store 图标保存回归和三项角标回归全部通过，日志 `Build/plugin-icon-tests.log`；六个 SF Symbols 在本机均可加载。设置页七项菜单已实机检查，Safari 工具栏实际显示 `arrow.down.circle` 与 `arrowshape.down.fill`；测试后设置恢复当前 PNG。 |
| 重复扫描角标回归 | Swift 3/3 通过，核心 22/22 重跑通过；`Build/badge-swift-tests.log`。验证同一数量连续 100 次扫描仍回传已显示角标且不重复更新、旧查询不能覆盖新页面、不同窗口独立及空页面清除。Safari 配置 2/2 重跑通过，日志 `Build/badge-configuration-tests.log`。 |
| 角标修复交付及实机抽查 | `Build/badge-release-build.log` 包含 `BUILD SUCCEEDED`，`Build/SiftX.app` 递归严格签名检查通过。运行中的原生扩展启动时间晚于新版可执行文件时间，确认已加载新版。当前已打开的媒体页显示 1 个 HLS 选项；连续两次手动刷新后数量仍为 1，关闭菜单后截图显示红点 1。此为实机抽查，未进行长时间逐帧闪烁测量。 |
| 实际媒体输出 | `/tmp/SiftXVerifiedMedia` 的 16 个历次 HLS/DASH 测试输出经本机 `ffprobe` 检查全部含 H.264 视频和 AAC 音频；原始检查数据保存在 `Build/media-verification.json`，下表保留首次最终测试的代表结果。 |
| 主 App 实机 | 开发签名 Release 已启动；原生 GUI 的 MP4、MP3、HLS 分离音轨、静态 DASH 下载均在 App Sandbox 中完成。默认 Downloads 符号链接访问问题已修复。 |
| 文件操作与历史 | HLS 文件经 Finder 正确定位并由 macOS 快速查看实际播放；主 App 退出、重开后完成记录保留。Release GUI 从历史重新下载 MP4 生成 `SiftX 2.mp4`，原文件保留且 SHA-256 一致。 |
| Safari 设置入口 | 用户完成开发者 unsigned 身份验证后实际运行。Xcode 自动生成的第二份 Debug App 已完整归档到 `Build/Archives/SiftX-Xcode-Debug-20261006-0918.zip`，仅保留固定交付路径的一对扩展；工程 Debug/Release 统一输出到该路径。 |
| Safari 配置回归 | Python 2/2 通过；验证原生功能键直接位于 NSExtension、完整 PDF 图标文件名与资源、探针点击入口保持原生 UI。`Build/safari-configuration-tests.log`。 |
| Release 构建 | 成功；`Build/release-build.log` 包含 `BUILD SUCCEEDED`。最终交付应用 `Build/SiftX.app`（1.0 build 3）；递归严格签名检查通过。 |
| Safari 基础链路 | **实机通过**。在 `127.0.0.1:18765/mp4.html` 播放视频；主按钮显示角标并打开原生 240p/426×240/约 1.5 MB 选项，Media Probe 按钮也打开同一菜单。下载箭头显示“已加入下载队列”，主 App 接管并在“已完成”显示文件。系统 Downloads 的输出与源文件 SHA-256 一致，证据在 `Build/safari-download-verification.json`。 |
| Safari 单按钮工具栏 | **实机通过**。通过 Safari“从工具栏移除”隐藏 Media Probe 图标后，工具栏仅保留 SiftX 主按钮；扩展设置中两个 SiftX 扩展仍勾选启用。新开本地 MP4 页面并播放，主按钮的原生菜单仍显示 1 个可下载选项（240p、426×240、约 1.5 MB）。 |
| 公共网页空媒体反馈 | 在用户已打开的必应 YouTube 内嵌视频页，原生菜单能打开；仅观察到浏览器内存媒体，显示解释和禁用下载按钮，没有将其列为可下载来源。 |
| 工具栏边界与交互 | 添加与批量操作属于整个窗口的导航工具栏，位于下载列表上方；在原有 980×650 窗口实机检查，与列表分栏边缘有可见留白。添加按钮打开链接 sheet，批量菜单显示三项操作；搜索 `mp4` 实际筛到一项，清空后恢复全部记录。 |

测试资源由 `Scripts/make_fixtures.py` 在本地生成，通过 `Scripts/fixture_server.py` 的 `http://127.0.0.1:18765/` 提供。没有把公共网站、登录平台或付费服务列为已验证来源。

## 16 项下载回归

源码：`Tests/DownloadTests/DownloadEngineTests.swift`。

| 测试 | 实际检查 |
| --- | --- |
| `testDirectAudioQueueCollisionAndDurableHistory` | MP4、MP3、并发队列、安全命名、同名后缀、完成历史持久化。 |
| `testPauseImmediateResumeProducesIdenticalFile` | 收到数据后立即暂停/继续，最终文件与源文件 SHA-256 一致。 |
| `testCancellationRetryAndFailureDoNotBlockQueue` | 立即取消/重试、403 明确错误、失败任务不阻塞后续下载。 |
| `testServerIgnoringRangeResetsPartialInsteadOfAppending` | 服务器忽略 Range 返回 200 时截断旧数据，结果与完整源一致。 |
| `testInterruptedConnectionRetriesAndMalformedRangeRestartsSafely` | 响应中途断开、自动重试、错误 Content-Range 安全重启。 |
| `testExclusiveFileCommitNeverOverwritesExistingMedia` | 独占原子提交；跳过或重命名策略均保留已有文件。 |
| `testDownloadFolderFollowsSandboxStyleDownloadsSymlink` | 模拟 `App/Data/Downloads` 相对符号链接，完成目录探测和实际文件提交。 |
| `testInterruptedStatusRecoveryAndDurableSafariRequest` | 重建管理器后中断任务变为暂停；持久 Safari 请求只接管一次并完成。 |
| `testHLSMasterSingleSplitAudioAndDASHGenerateMediaFiles` | HLS master、单清晰度、分离音轨、静态 DASH 均生成实际 MP4。 |
| `testProtectedMediaFailsWithClearExplanation` | SAMPLE-AES/FairPlay 示例被拒绝，并显示 DRM/不支持加密的说明。 |
| `testHistoryFileAccessSurvivesFolderChangeAndMissingFileRemoval` | 文件 bookmark 持久化、切换默认目录后的历史访问/删除、原文件缺失时删除记录。 |
| `testHTTP200LoginHTMLAndJSONAreRejectedInsteadOfSavedAsMedia` | 200 HTML/JSON 登录响应被拒绝，不生成伪媒体文件。 |
| `testAES128VariantsDecryptToOriginalSegmentsAndProducePlayableMedia` | 七种 AES-128 HLS（默认/显式 IV、轮换/明文混合、ByteRange、master、加密 fMP4 初始化段、独立音轨）输出逐分片与原素材 SHA-256 一致。 |
| `testConcurrentSegmentsShareKeyAndRotationRefetchesWithReferer` | 20 个并发需求只取一次作用域密钥；新作用域重取，Referer 保留。 |
| `testInvalidOrInaccessibleKeysAndCorruptCiphertextFailClearly` | 短/长密钥、403、HTML 伪密钥、损坏密文均明确失败，不提交完成分片。 |
| `testPauseResumeKeepsCompletedPlaintextChunksAndSkipsTheirRequests` | 中途取消模拟暂停，再下载复用已完成明文分片且不重复请求；哈希保持一致。 |

测试清理已改为 XCTest teardown 阶段关闭工作任务后移除临时 Store。最终 12 项测试日志没有 SQLite vnode-unlinked 诊断。此前一次服务器关闭造成的首项超时，在恢复本地服务器后重跑已通过。

## 输出文件检查

2026-10-06 使用本机完整 FFmpeg 的 `ffprobe` 检查全部测试下载产物。下列 4 个来自 2026-10-05 的 Xcode 测试；后续重跑及较早独立 XCTest 的输出同样含 H.264/AAC。

| 输出文件 | 视频 / 音频 | 时长 | 字节数 |
| --- | --- | --- | --- |
| `1AAAB136-6847-425E-8AEC-4CD9B2672377.mp4` | H.264 426×240 / AAC | 12.032 秒 | 1,551,218 |
| `2FBB5C6F-06FD-4D4A-801F-082F7B1E1A72.mp4` | H.264 426×240 / AAC | 12.032 秒 | 1,551,218 |
| `58883A76-655D-4A43-B984-7DB6AD3D41DB.mp4` | H.264 426×240 / AAC | 12.032 秒 | 1,551,202 |
| `E8596C64-8E3D-4A7F-A3A7-D98FE426807F.mp4` | H.264 426×240 / AAC | 12.010 秒 | 1,549,215 |

复现命令与测试站点启动步骤见 [README.md](README.md)。临时输出与 `Build/` 日志属于本机验证产物，可能被清理。

实际 Release 沙盒 GUI 产物也经 `ffprobe` 检查：

| 文件（系统 Downloads） | 内容 | 时长 / 字节数 |
| --- | --- | --- |
| `SiftX HLS 分离流测试.mp4` | H.264 426×240 / AAC | 12.032 秒 / 1,551,202 |
| `SiftX DASH 测试.mp4` | H.264 426×240 / AAC | 12.010 秒 / 1,549,215 |
| `SiftX 音频测试.mp3` | MP3 音频 | 12.011 秒 / 96,724 |

主窗口及设置的浅色/深色显示已检查，测试后恢复为跟随系统。Safari popover 浅色实机与当前 SwiftUI 视图的浅色/深色布局已检查；Safari 宿主中的系统深色切换仍待验证。

## Safari 人工验收步骤

先启动开发签名 App，在 Safari → 设置 → 扩展启用 **SiftX Safari Extension** 和 **SiftX Media Probe**，为本地测试站点允许访问。首次系统授权需用户执行。

1. 打开测试站点的 MP4、audio 页面并播放；检查工具栏整理后的数量、视频缩略图和音频波形。点击预览检查内容、分辨率、声音、进度与音量，返回后再检查下载按钮。
2. 分别打开 HLS master、single、split audio 和 DASH 页面；检查质量选择、音轨组合，下载后打开文件确认声画。
3. 同时打开两个相同 URL 的 Tab；在不同 Tab 播放不同资源，确认当前页面选择不会串到另一 Tab。
4. 刷新、跳转、使用 SPA 示例切换页面，关闭再打开 Tab；确认旧候选及时清理，迟到请求不污染新页面。
5. 打开 hls-aes/hls-aes-audio 示例验证普通 AES-128 下载；blob 与 protected 示例分别检查内存地址及 DRM 说明和禁用状态。
6. 从 popover 提交任务后关闭 popover 或 Safari；确认主 App 继续下载并保存历史。
7. 退出并重开 App、重启 Safari、停用再启用扩展；确认状态恢复和页面握手重新建立。
8. 下载 slow 示例时暂停/继续、断网/恢复网络；检查速度、进度、错误说明及恢复结果。
9. 检查 Finder 定位、打开文件、切换默认目录后访问旧文件、从 Finder 删除原文件后的历史状态。
10. 在浅色和深色外观中检查主窗口与 Safari popover；分别允许/拒绝通知，确认下载正常运行、通知不过度重复。

## 未验证与产品边界

- Safari 基础 MP4 发现、两个按钮的原生 popover、实际下载链路，以及 MP4/MP3/加密 HLS 独立音轨预览已通过。Safari 重启、真实多 Tab/SPA、Safari 中完整 HLS/DASH 下载选择、系统深色 popover 及扩展拒绝网站访问的 UI 仍待上述验收；对应逻辑的自动化测试不能代替这些交互检查。
- 通知系统授权后的实际投递、拒绝权限后的 GUI 行为及登录项系统批准流程尚未记录为通过。
- 未测试 Intel Mac、macOS 14–26 实机或公开分发/公证版本。
- 普通 AES-128 HLS 已支持并完成本机下载验证。DRM/SAMPLE-AES、加密 I-frame 专用列表、非 HTTP(S) 密钥、直播录制、SIDX SegmentBase、多 Period DASH 不受支持；直播和 DRM 平台没有被列为可下载来源。
- 浏览器 `blob:` 本身不可下载；需要可发现的底层普通媒体 URL。依赖 Safari 登录 Cookie、专有授权或特殊播放器协议的站点未获兼容性保证。

## Safari 下载面板与类型筛选（2026-10-06）

面板顶部固定“全部 / 视频 / 音频”筛选，文件和去重后的无法下载原因按媒体类型同步更新。新打开面板默认全部，刷新保留选择；页面级错误仍显示。含音轨的视频归入视频类型。底部刷新与打开 SiftX 始终可见，长列表在 336pt 内容区滚动，面板总高度最多 429pt。

Release 构建与 `codesign --verify --deep --strict` 通过。使用实际 SwiftUI 视图的临时原生预览检查了全部、视频、音频、无音频、视频分析中、权限错误和长列表七种状态的浅色/深色布局，文字与控件完整。混合候选、对应类型的原因、空结果、分析中状态和页面级错误通过预览断言；同一视图实时切换音频与全部后，结果与高度正确更新。此预览不代表 Safari 已重新加载扩展后的实机验收。

## 2026-10-06 下载面板紧凑布局

面板宽度由 390pt 调整为 195pt。视频主行显示分辨率，次行只显示协议/格式与已知时长；缺少分辨率时回退清晰度或媒体类型。

Release 构建与签名验证通过。使用当前 SwiftUI 视图的临时原生预览检查全部、视频、音频、无音频、视频分析中、权限错误和长列表七种状态的浅色/深色布局，所有输出宽度为 195pt；1920×1080、HLS · 41:03 与下载/底部按钮完整显示，长列表总高仍为 429pt。实时切换筛选后高度正确更新。此预览不代表 Safari 已重新加载扩展后的实机验收。

## AES-128 交付与实机验证

- Release 构建成功，`Build/aes-release-build.log` 含 BUILD SUCCEEDED，严格递归签名验证通过；交付保持 `Build/SiftX.app`。
- 核心 35、角标 3、下载 16、JS 35、Safari 配置 2 项全部通过；配置日志为 `Build/aes-configuration-tests.log`。
- `Build/VerifiedAES128/` 七种自动化输出均为 H.264 426×240 / AAC、12.032 秒；`ffprobe` 和完整音视频解码均无错误，证据为 `Build/aes-output-verification.json`、`Build/aes-decode-verification.json`。
- 实际 Release 沙盒应用中，通过添加链接读取本机 AES-128 分离音轨示例，显示 240p 与仅音频两个可下载选项、0:12 时长及 AES-128；240p 下载完成，详情显示视频 + 音频、426×240 和 AES-128。完成文件另经完整解码验证。
- 用户于 2026-10-06 确认可从原网站下载；没有将所有公共网站兼容性记为通过。此次新增跨扩展强制刷新/登记恢复有 JS 回归和编译验证，仍需后续 Safari 扩展重启交互验收。
