# 功能

Last reviewed: 2026-10-07

| 用户能力 | 实现位置与证据 |
| --- | --- |
| Safari 自动发现媒体、去重、过滤分片、质量聚合 | `MediaProbe/`、`SiftXCore/MediaAnalyzer.swift`；JS 与核心测试通过；Safari 本地 MP4 实际发现 240p、426×240、约 1.5 MB |
| 当前页面原生 toolbar/popover | `SafariExtension/`、`Popover/SiftXPopover.swift`；两个工具栏按钮均实际打开同一 SwiftUI popover；本地 MP4 提交、接管、完成及文件 SHA-256 一致性已验证 |
| 下载前预览、视频缩略图与音频试听 | `SafariExtension/Preview/`、`PreviewNetworking/`；Safari 实机 MP4、MP3、AES-128 HLS 独立音轨及错误反馈通过，5 项预览集成测试通过 |
| MP4/音频、HLS master/single/独立音轨、静态 DASH | `HLSParser`、`DASHParser`、`App/Downloads`；实际 HTTP 输出与 ffprobe 通过 |
| 网页或媒体链接下载 | `SiteMediaDownloader`、`MediaAnalyzer`；Safari 提供视频/音频选项，⌘N 读取清晰度，保存视频或仅音频；持久请求保留所选视频部分与格式身份 |
| 普通 AES-128 HLS、密钥轮换、默认/显式 IV、加密初始化段/独立音轨 | `HLSParser`、`HLSAES128`、`HLSKeyLoader`、`EncryptedHLSTests`；七种实际输出逐分片 SHA-256 与原始素材一致，输出 H.264/AAC 并通过完整解码 |
| 队列、并发、进度/速度/大小/合理 ETA | `DownloadManager`、`DownloadRow`；原生队列集成测试通过 |
| 暂停/继续、取消/重试、批量操作 | `DownloadManager`；立即恢复与取消/重试回归通过 |
| 文件名清理、同名处理、默认目录 | `DownloadFiles`、设置页；独占提交与 sandbox 风格符号链接回归通过 |
| 已完成下载详情内视频/音频预览、重下载、复制来源、Finder、打开/删除 | `App/Views/DownloadDetail.swift` 使用本地 AVPlayer，视频搭配 AVPlayerView，音频使用 SwiftUI 控件；bookmark、缺失文件、持久化回归通过；Release GUI 的 Finder 定位及 macOS 预览播放通过；详情内播放器验收另见验证记录 |
| 重启恢复、持久 Safari 请求 | `SharedStore`、`DownloadManager.start()`；状态恢复和一次接管回归通过 |
| 设置、引导、菜单栏、外观、通知、登录项、关闭最后一个窗口后退出或留在托盘 | `SiftXApp`、`SettingsView`、`OnboardingView`、`MenuBarView`、`ApplicationModel`、`AppSettings`；退出模式持久化，关闭最后一个窗口由应用 delegate 按设置终止进程或保留菜单栏运行 |
| Safari 插件图标选择 | `SettingsView` 的 Safari 页提供当前 PNG 和六种 SF Symbols；`AppSettings` 共享保存，原生扩展工具栏验证时应用，主 App 通过消息触发刷新 |
| 设置中的使用说明 | `App/Settings/SettingsView.swift` 的“关于”页说明下载工具用途，完整展示免责声明与版权/授权素材的使用提示 |
| Safari 下载数量红点开关 | `SettingsView` 的 Safari → 工具栏提供“显示下载数量红点”，默认开启；共享保存，主 App 通知工具栏刷新，关闭时验证立即返回空角标 |

Safari 下载面板宽度为 195pt，视频条目主行显示分辨率（无尺寸时回退清晰度或媒体类型），次行只显示协议/格式与已知时长；描述允许换行。顶部提供“全部 / 视频 / 音频”筛选，可下载文件和去重后的无法下载原因随选择更新；原因直接以正文显示，空结果提示对应的媒体类型。打开面板默认全部，刷新保留选择。顶部筛选与底部刷新、“在 SiftX 中打开”始终可见，面板根据内容调整高度，长列表滚动。实现：`SafariExtension/Popover/SiftXPopover.swift`。

视频条目左侧展示可点击的 48×32pt 缩略图，优先网页封面，其次静音提取媒体画面；音频保留波形图标并可点击试听。点击后面板扩展到 560×440pt，展示播放器、分辨率、时长和音轨状态；提供播放/暂停、进度、音量、返回及下载入口。返回恢复 195pt 列表和当前筛选，关闭或页面切换停止预览。预览按需流式读取，只有点击下载才提交任务。部分网页媒体使用网页播放器，受网站嵌入限制；失败可重试或在原网页打开。

Safari 工作流：播放网页 → 当前会话出现整理后的选项 → 点击缩略图预览确认 → popover 提交下载请求 → 主 App 接管 → 普通下载或本地合并 → 下载管理与 Finder。主 App 也支持 ⌘N 添加媒体链接。

主窗口使用“左侧导航 + 主内容区”的两栏布局。边栏“下载管理”分组依次提供全部下载、正在下载、已完成、失败；“媒体类型”分组提供视频、音频、其他。默认选中“全部下载”，按创建时间倒序显示所有状态的持久下载记录。正在下载包含下载和文件整理中的任务，右侧显示实时数量，零时隐藏；排队、暂停、取消可在全部下载中查看。视频/音频按候选类型筛选所有状态的记录，其他保留兜底入口，当前模型只产生视频和音频。搜索继续按媒体标题或网页名称筛选当前分类。点击下载行后，同一区域进入该记录的详情，系统返回按钮或点击任一边栏项回到列表。各行显示任务状态，未完成任务支持暂停、继续、重试和删除，已完成任务可查看文件与本地预览。实现：`App/Views/MainView.swift`。

已完成记录的详情顶部提供本地媒体预览：视频显示画面和原生播放控件，支持进度和音量控制；音频以单行播放/暂停图标和进度滑条呈现，位于详情表单上方。用户点击播放后才开始。音频进度支持拖动与键盘调整，可访问名称和进度通过辅助功能提供。切换记录或离开详情会停止并释放播放器。文件缺失或授权不可用时显示提示；格式无法播放、播放中断或加载超时可重试，并可使用原有“打开文件”入口。实现：`App/Views/DownloadDetail.swift`。

Safari 工具栏可只显示 SiftX 主按钮，Media Probe 图标通过自定工具栏隐藏。2026-10-06 本机实测：隐藏后两扩展仍启用，原生菜单仍显示本地 MP4 的 240p、426×240、约 1.5 MB 选项。操作方式：在 Safari → 显示 → 自定工具栏中移除 Media Probe 图标，并保持两个扩展启用。

## 边界

- 支持普通 AES-128 HLS 的 HTTP(S) identity 密钥；不录制直播，不下载 DRM/SAMPLE-AES、加密 I-frame 专用列表或非 HTTP(S) 密钥。
- DASH 支持常见单 Period 静态 SegmentTemplate/Timeline、SegmentList、直接媒体 BaseURL；SIDX SegmentBase、多 Period、目录型 BaseURL 无媒体分段信息不受支持。
- DASH 原生预览需要可转换为 HLS 的 fMP4 初始化段及真实分片时长；不具备这些信息或系统不支持编码时，提供原网页入口。网页预览的画质由网页播放器选择。
- `blob:` 需要找到底层普通媒体 URL；仅有内存地址时给出说明。
- 部分网页视频通过随包媒体解析器处理内存播放与分离音轨；不读取 Safari 登录状态，提供当前可公开访问的兼容格式。视频使用网页预览时受嵌入权限限制，音频可在原网页试听；不支持的页面需改用完整的单视频页面链接。
- 不保证依赖 Safari 登录 Cookie、特殊签名或站点专有播放器协议的来源；过期/登录网页、403、404 和服务器异常会明确失败。
- 私人浏览观察不写入共享页面媒体状态；没有云同步、广告、分析 SDK。
- Apple silicon / 本机 macOS 27 已验证；Intel、旧系统、公开发布签名与公证另验。

完整通过项、自动化范围和 Safari 人工步骤见 [VERIFICATION.md](../../VERIFICATION.md)。

2026-10-07 下载工具说明更新：README 使用用户提供的两张原图并仅介绍简单功能；设置 → 关于的免责声明与使用提示、添加链接窗口的通用文案均已实机确认完整显示。47 项核心回归、Release 构建及深度严格签名检查通过；该轮没有修改解析、下载、队列或持久化逻辑。

2026-10-07 本轮自动化验证通过 47 项 Swift 核心、21 项实际下载、35 项 JS 和 2 项 Safari 配置回归，包含新增 5 项网页链接核心与 2 项下载用例。其他 Swift targets 无失败；5 项预览集成本轮因未配置测试站点按条件跳过，此前的实机与预览集成记录见 VERIFICATION。角标回归覆盖 100 次重复扫描不清空/重写、迟到查询与窗口隔离，探针回归覆盖重复发布去重、心跳、失败重试及分析中的重复观察。固定交付路径 `Build/SiftX.app`，既有实机下载验证覆盖直接 MP4/MP3、HLS 分离音轨和静态 DASH；本轮网页链接经 Safari 按钮提交、Release 应用接管并完成 1080p H.264/AAC MP4，详见验证记录。

HLS/DASH 候选不再把播放清单的 Content-Length 展示为视频大小；HLS 有码率时按时长估算，无码率时省略大小。时长与 AES-128 信息保存于可选字段，兼容旧记录。菜单刷新触发跨扩展重新登记和强制分析；后台丢失页面登记时资源发布自动恢复。
