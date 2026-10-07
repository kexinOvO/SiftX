# 维护记录

Last reviewed: 2026-10-07

- 第三方发布材料以 `ThirdParty/sources.lock.json` 和 `runtime-files.json` 为固定版本输入。源码归档、原始许可、上游 requirements/CMake/build 脚本与项目集成脚本会生成离线源码 ZIP；Release 会将应用和源码 ZIP 一起打包。修改随包工具后必须重新核对匹配源码并更新清单，禁止仅更新二进制沿用旧材料。代码签名修改发生在构建副本，runtime 清单针对 `App/Resources` 原始资源。维护说明见 `ThirdParty/README.md`；源码版本依据与上游构建可复现范围见 `PROVENANCE.md` 和 `BUILDING.md`。

- 网页 MSE 播放器的 `blob:` 不是下载地址，底层 `.m4s` 不能通过全局放行分片规则解决。支持的普通视频页路由到主应用的站点解析器，复用随包 yt-dlp 重新解析签名地址，选择 H.264/AAC 并合并。持久候选只保留规范视频页、所选视频部分和可选格式 ID。`SiteFormatSelection` 为公共格式身份，旧格式选择类型保留兼容别名；站点格式选择使用可选字段，旧历史可继续解码。

- 手动重签主 App 必须使用本次 Xcode 构建生成的 `SiftX.app.xcent`，不能直接使用含 `$(DEVELOPMENT_TEAM)` 的 `Config/App.entitlements`。最终签名里的 App Group 必须与 Info.plist 的 `SiftXAppGroupIdentifier` 一致；`codesign --verify` 只校验签名与资源完整性，还需核对实际授权并启动验证共享资料库访问。授权模板误入最终签名会导致 SQLite 启动报 `authorization denied`，无需删除资料库。

- `Scripts/generate_project.py` 的 FFmpeg 和媒体解析工具签名阶段每次构建都会执行；增量 Release 可能重新签名嵌套资源却跳过主 App 的 CodeSign，造成主包资源封存失效。2026-10-06 已定位到此情况：两个 appex 验签通过，主包报工具资源被修改。最小恢复是使用本轮生成的 `SiftX.app.xcent` 和原签名身份，仅重新签名外层 `Build/SiftX.app`，保留 identifier/flags/runtime；签名时不用 `--deep`，随后用 `--verify --deep --strict` 验证完整包。

- Safari → 工具栏的“显示下载数量红点”通过可选 `toolbarBadgeVisibleFlag` 持久化，旧设置默认开启。图标与红点选择变化均触发原有工具栏刷新消息。关闭时立即返回空角标、清空窗口缓存并废弃旧请求，异步页面回复后需重读偏好。回归在 `CoreTests` 的旧设置兼容/跨 Store 保存测试及 `ToolbarBadgeTests` 的关闭/重新开启/迟到查询测试。

- 已完成详情内的预览只读取下载完成的本地文件，沿用 `DownloadFileLease`，不要复用 Safari 的网络代理或网页播放器。播放器与 security-scoped 文件授权必须同寿命；视频使用原生播放控件，音频使用位于表单上方的单行播放按钮和进度滑条。切换记录/离开详情时移除周期时间与状态观察，暂停并清空播放项，再释放授权。实现：`App/Views/DownloadDetail.swift`。

- “退出软件行为”保存在 `AppSettings.exitBehaviorRawValue`；缺失或未知值回退到“关闭软件”。`SiftXApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed` 控制关掉最后一个窗口后退出进程或保留到菜单栏。选择“退出至托盘”时，菜单栏图标必须可见，设置页会显示并锁定该入口；重开菜单项通过主窗口内容注入的 `openWindow(id: "main")` 与弱窗口引用恢复窗口，不依赖会随导航变化的标题。

- 主窗口边栏使用“下载管理”（全部下载、正在下载、已完成、失败）和“媒体类型”（视频、音频、其他）两个分组，默认全部下载。正在下载的筛选与角标共用 `.downloading/.processing` 语义，数量读取 `DownloadManager.activeCount`，零时隐藏且不受搜索影响；失败只包含 `.failed`。媒体分类依据 `candidate.kind`，当前只有 video/audio，“其他”作为兜底入口。搜索按媒体标题或网页名称筛选当前分类，列表按创建时间倒序排列。两栏 `NavigationSplitView` 的主区内使用 `NavigationStack` 和下载 UUID 路径，点击行进入详情，系统返回或任一边栏项回到列表。详情记录被移除时清空路径；按 UUID 读取当前记录以继续显示实时状态。任务行和详情依据各自状态提供操作。筛选与导航定义在 `App/Views/MainView.swift`。

- 主窗口内容的最小尺寸为 640×400pt，定义在 `App/Views/MainView.swift`；默认打开尺寸仍由 `App/SiftXApp.swift` 的 1080×650pt 控制。边栏最小宽度 170pt，主内容区最小宽度 360pt。

- Safari 媒体列表的下载按钮使用粗体 `arrow.down`，macOS 26.1+ 声明透明 Liquid Glass 样式 `.glass(.clear)`，macOS 26.0 使用 `.glass`，更早系统回退 `.bordered`；共用 `.circle` 形状、`.small` 控件尺寸和 `.title3` 基础字号。按钮背景按 1.2 倍缩放，箭头通过内层补偿最终呈现为基础尺寸的 0.7 倍。`MediaChoiceRow` 垂直居中，提交后显示原尺寸常规字重勾号并禁用按钮。

- 下载前预览保留 195pt 媒体列表，视频使用可点击的 48×32pt 缩略图，音频保留波形并可试听；播放器展开到 560×440pt，返回保留筛选。关闭 popover、返回或文档上下文变化必须清除播放器、观察、准备任务和回环代理。
- 预览通过 `MediaPreviewProxy` 保留 Referer、Range、HLS 独立音轨与 AES-128 资源，不依赖非公开 AVURLAsset header 选项。监听仅绑定 127.0.0.1，注册 URL 含随机作用域；不持久保存预览媒体或密钥。同一密钥 URL 的不同 EXT-X-KEY 声明须使用独立代理路径，防止播放器复用过期密钥。
- HLS 的 `loadTracks(.audio)` 可能返回空数组；确认声音要同时读取 audible media selection group。DASH 预览仅在有初始化段与真实分片时长时转换 fMP4→HLS；`DASHRepresentation` 新增元数据不得改变下载使用的既有 segments。
- 预览 XCTest 位于 `Tests/MediaPreviewTests`，设置 `SIFTX_PREVIEW_FIXTURE_BASE_URL` 并启动当前 fixture server 才运行实际播放器检查，未设置时跳过。2026-10-06 五项通过，Safari MP4/MP3/加密 HLS 独立音轨与错误反馈实机通过，完整证据见 VERIFICATION.md。

- 网页媒体入口支持规范化的单视频页面、短链接及嵌入页面；不把浏览器内存地址或过期媒体地址当作持久下载来源。Safari 可在播放前提供自动视频与仅音频动作，具体画质在主 App 的 ⌘N 中读取。

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
- Safari 本机基础链路现已实际通过：两按钮打开原生菜单，MP4 发现质量信息并提交到主 App，完成文件与源 SHA-256 一致。验证结果在 VERIFICATION.md。公共搜索结果内嵌视频页面仅发现内存媒体，显示解释而非可下载结果。
- MainView 的添加/批量操作与 searchable 放在整个 NavigationSplitView 上，操作使用 navigation placement，位于下载列表上方；在 980×650 实机窗口验证分栏边界留白、添加 sheet、批量菜单和搜索筛选。保持系统原生工具栏样式。

- 应用图标采用 `App/Resources/AppIcon.icon/` 的 Icon Composer 分层资源，来自用户的 `siftX.icon` 原文件。Xcode 用 `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` 编译系统图标外观到 `Assets.car` 并生成兼容 ICNS，支持 macOS 系统设置 → 外观 → 图标与小组件样式。工程生成器将 `.icon` 作为整体资源引用。原尺寸默认 PNG 另保存在 `Scripts/Assets/AppIcon.iconset/`，六种外观的 1024px 导出参考保存在 `Scripts/Assets/AppIconPreviews/`。

- Safari 顶部媒体类型筛选使用 `GlassMediaFilterPicker`：毛玻璃胶囊容器、`GlassLens` 选中透镜与滑动动画，绑定 `PopoverMediaFilter`；顶部区域为 44pt。
- Safari 下载面板以 `protection == nil` 过滤文件列表，其他候选只提供去重后的原因；正在分析的候选显示加载状态。类型筛选使用 `MediaCandidate.kind`，带音轨的视频属于视频；文件和受限原因按相同类型筛选，页面级错误始终可见。面板每次打开默认全部，刷新保留选择。顶部固定类型筛选，底部保留刷新及打开 App。SwiftUI 内容高度测量同步到 Safari preferredContentSize，长内容在 336pt 内容区滚动，总高最多 429pt。

- Safari 下载面板统一宽度为 195pt，由 `PopoverLayout.width` 同时控制 preferredContentSize 和 SwiftUI 根视图。条目用分辨率作为主行，协议/格式与时长作为次行；缺少尺寸时回退已有清晰度或媒体类型，缺少时长时不虚构。紧凑布局采用 12pt 横向留白、8pt 行间隔，描述可换行。2026-10-06 Release 构建、签名验证与七种状态的浅色/深色原生预览通过；Safari 重新加载后的实际显示仍需实机确认。

- 普通 AES-128 HLS 的描述只保存 keyURL/IV/keyID，不保存密钥字节；keyID 由播放清单 URL 和 EXT-X-KEY 次序决定，包含音轨及同 URL 新作用域。EXT-X-SESSION-KEY 不代替子播放清单的 EXT-X-KEY；初始化段加密需要显式 IV，初始化段不推进媒体序号。
- 解密读取新 FileHandle 的实际长度，不依赖 NSURL 缓存的 resourceValues 文件大小；完整验证 PKCS#7 的所有填充字节，失败不发布 .chunk。暂停保留密文 .part 与已完成的明文 .chunk；计划包含加密描述，指纹变化时重建分片目录。回归见 HLSEncryptionTests、EncryptedHLSTests。
- 16 项下载回归、35 项核心、3 项角标、35 项 JS 和 2 项配置测试通过；七种 AES-128 输出与原始分片 SHA-256 相同，均为 12.032 秒 H.264/AAC，完整解码无错误。记录在 Build/aes-*-tests.log 与 Build/aes-output-verification.json。用户于 2026-10-06 确认原网站可以下载；网站兼容性仍需逐站验证。
- 用户刷新需要强制 native 清理分析缓存，而普通重复观察继续去重。页面宣布仅在后台确认相同 sessionID 后缓存成功；后台丢失登记时，resources 先重新登记再补发。JS 回归覆盖强制刷新、错误会话/iframe 拒绝和登记恢复。

- 下载工具的介绍、添加链接提示、错误反馈和媒体格式显示采用通用文案；原有传输枚举、持久化字段、站点校验、处理流程和第三方归属保持兼容。用户说明在 README，仅介绍简单功能并使用 `docs/images/` 中的界面截图；技术与构建说明保留在项目上下文和第三方许可文件。设置 → 关于完整显示免责声明：该工具仅供学习使用，下载的素材请在24小时内删除，任何个人行为与软件开发者无关。该页另提供版权/授权素材及来源使用条款提示，删除期限仅为使用要求。

- 2026-10-07 解锁后，网页链接的 Safari → Release 主应用实际下载链路通过：刷新页面出现视频/音频入口，视频任务完成并保存 75.7 MB、1920×1080 H.264/AAC MP4，时长 11:04.56；“打开文件”成功载入 IINA，辅助功能状态未提供连续播放证据。详细验收见 VERIFICATION.md 与 `Build/bilibili-verification/safari-release-verification.json`。
