# 架构

Last reviewed: 2026-10-06

## 组件边界

1. Web Extension 观察 DOM、Performance 和 webRequest，将普通媒体观察交给 native probe；工具栏点击通过当前 Tab 顶层脚本转发给原生 popover；不展示 HTML popup，不下载大型媒体。
2. Native probe 校验输入、分析 HLS/DASH、聚合可选媒体并更新共享 PageSession。
3. Safari App Extension 查询当前 SFSafariPage 的页面 UUID，在原生 SwiftUI popover 将可下载候选与无法下载原因分开展示；点击下载只提交持久 DownloadRequest 并唤起 App。
4. 主 App 的 DownloadManager 轮询请求、持久化任务后确认接管，按照并发限制执行下载；popover 关闭不影响已接管任务。

原生扩展的 `SFSafariToolbarItem`、`SFSafariContentScript`、`SFSafariWebsiteAccess` 必须为 `NSExtension` 的直接子键。工具栏验证立即返回可用及该窗口已显示的角标，页面发现异步更新计数；相同数量不重复写角标，过期查询不得覆盖新查询。状态在 `SafariExtension/State/ToolbarBadgeState.swift` 内加锁，独立 Swift package target 供回归测试。PopoverLayout.width 将列表宽度固定为 195pt（原 390pt 的一半）；内容测量后更新高度，滚动内容区最多 336pt，顶部固定类型筛选，底部固定刷新与打开 App 入口，整体最多 429pt。控制器通过统一尺寸回调将预览扩展为 560×440pt，返回时恢复记住的列表尺寸。

探针后台按成功发布的完整观察快照去重；相同 DOM/网络观察不重复调用 native 或通知工具栏。相同快照每分钟允许一次存储心跳，只有观察或 native 返回的可下载数量变化才通知页面；native 失败仍可重试。已有候选在 HLS/DASH 重新分析时保留，分析结束后整体替换，避免临时分析状态清空角标。

日常工具栏只需保留原生 SiftX 按钮。Media Probe 的按钮可通过 Safari 自定工具栏隐藏；工具栏显示与扩展启用、网站权限分别管理，后台 DOM/网络发现仍继续。两扩展均需保持启用。

页面 UUID 绑定每个文档/SPA 代际。两套注入脚本通过文档上下文握手共享 token；原生扩展向当前 SFSafariPage 发送带 nonce 的查询并等待对应响应。URL 和 Web Extension Tab ID 不作为跨扩展的唯一键。依据：`SafariBridge.js`、`content.js`、`PageContextResolver`、JS 会话测试。

## 下载前预览

`PopoverModel.previewCandidate` 管理列表与预览切换，关闭 popover 或页面 UUID 变化时清除。`MediaPreviewPlayback` 在用户点击后创建 AVPlayer，观察就绪、失败、画面尺寸和音轨；返回时取消准备与超时任务、清除播放器和网络代理。音轨判断同时读取 audio tracks 和 audible media selection group，兼容 HLS 独立音轨。

`MediaThumbnailLoader` 优先读取网页封面或 YouTube 封面，其次以静音 AVPlayer 提取视频帧；图片缩采样并只在内存缓存，限制两个并发任务、图片响应大小和提帧时间。音频仍显示原波形图标。

`MediaPreviewProxy` 是预览专用 actor，通过 Network.framework 在 127.0.0.1 的临时端口提供带随机作用域的注册资源，只允许 GET/HEAD；URLSession 不保存 Cookie、响应缓存、媒体或密钥。它保留允许的 Referer、Range 与响应范围，重写 HLS 分片、初始化段、音轨和密钥 URL，按 EXT-X-KEY 声明为相同密钥 URL 分配独立路径。HLS master 只包含当前所选视频与对应音轨。DASH 解析器另行保留初始化段及真实分片时长，代理将支持的 fMP4 表示转换为 HLS；既有下载分片序列保持兼容。原生扩展的 network.server entitlement 用于这个仅绑定回环地址的监听器。

YouTube 使用非持久 WKWebView 网页播放器，包含超时、重试和原网页入口，关闭时停止并清空网页。原生预览的画质对应所选候选；YouTube 网页播放器自行选择画质。预览不创建 DownloadRequest，只有显式下载动作沿用原有持久队列。

## 共享存储

App Group 为 `$(DEVELOPMENT_TEAM).com.siftx.shared`，由各 target 的 `SiftXAppGroupIdentifier` Info.plist 键传给共享模块。`SharedStore()` 在缺失共享容器时明确失败，不静默拆成进程私有数据库。

共享容器内 `SiftX/Shared.sqlite` 保存 pages、requests、downloads、settings。SQLite WAL、FULLMUTEX、进程内锁、忙等待及短事务处理跨进程写入。下载请求使用稳定 UUID：先保存 DownloadRecord，再 ack 请求；中间崩溃后的重复接管不会重复建任务。

插件图标保存于 `AppSettings.pluginIcon`，缺失或未知值通过 `selectedPluginIcon` 回退到当前 PNG。Safari 正在运行时，主 App 保存选择后通过 ObjC 回调桥发送 `siftx.toolbarIconChanged`，扩展触发所有窗口的工具栏验证；验证先读取共享设置并调用 `setImage`，再异步查询页面角标。PNG 使用 `setImage(nil)` 恢复 Info.plist 资源，系统图标使用模板 NSImage。Safari 关闭时只保存选择，下一次验证应用。

红点显示由 `AppSettings.toolbarBadgeVisibleFlag` 共享保存，`showsToolbarBadge` 在缺失字段时默认 true；保存变化复用工具栏刷新消息。`ToolbarBadgeState.beginValidation` 在隐藏时清空该窗口文本并使此前异步查询失效；隐藏期间数量更新不得恢复角标。页面查询返回后再次读取偏好，避免查询等待期间的关闭操作被迟到结果覆盖。

退出行为使用可选原始值保存在 `AppSettings` 中；旧设置缺少此字段时默认“关闭软件”。`SiftXApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed` 在最后一个窗口关闭后按选择结束进程或保留应用，托盘模式会确保菜单栏图标可用。菜单栏打开入口使用 SwiftUI `openWindow(id: "main")` 与弱窗口引用重开主窗口，不依赖导航标题。

页面最多 200 个、候选每页最多 100 个，两个小时未更新清理。原始网络分片不进入历史。持久候选去掉 MediaPlan；下载时重新生成分片计划。分析器限制响应大小、缓存数量和存活时间。

## 下载与文件

- MainActor 管理可观察队列与记录；DownloadEngine actor 执行业务，URLSession 串行 delegate 将数据直接写盘。
- 直接媒体使用 ETag/Last-Modified 与 If-Range 恢复；200 响应重置部分文件，错误 206 范围重启。无可验证身份的部分文件重新下载。
- 普通 AES-128 HLS 每个分片携带密钥 URL、作用域 ID 与 16 字节 IV；主 App 的 HLSKeyLoader 按作用域合并并发请求，密钥只在任务内存保留，严格检查 16 字节响应及重定向。HLSAES128 使用 CommonCrypto CBC 流式解密并完整验证 PKCS#7，成功后才提交分片；视频、音频和初始化段统一走此流程。
- 每个分片下载流式写盘；每任务最多 4 个并行分片。完成分片以编号文件保留，计划 fingerprint 变化会重建分片目录。
- 中间文件放在共享容器 `SiftX/Transfers/<task UUID>`。完成、取消、删除及启动孤儿清理回收文件；暂停和失败保留可恢复进度。
- HLS/DASH 拼接本地 TS/fMP4 输入后启动内置 FFmpeg；命令仅包含本地路径，处理器只支持 `file,pipe`，使用 stream copy。
- 目标目录使用 security-scoped bookmark；完成文件保存自己的 bookmark。DownloadFileLease 支持后续打开、Finder 定位和删除，不依赖当时的默认目录。
- 已完成详情的 `CompletedMediaPlayback` 持有 `DownloadFileLease` 直到本地 AVPlayer 停止；视频使用原生 AVPlayerView，音频用 SwiftUI 播放按钮和 Slider，通过播放器状态、时长观察及周期时间观察同步控件。音频的播放结束通知设置终点状态，再次播放先回到起点。状态观察、播放通知、时间回调和超时使用 generation 防止过期回调，seek completion 另有请求代际；离开详情先移除观察、清空播放项，再释放文件授权。
- 文件先复制到目标文件系统的临时路径，再独占原子 rename。已有文件得到数字后缀或明确跳过，不覆盖。
- 重启后 `.downloading/.processing` 转 `.paused`；异步进度回调携带 worker generation，防止旧任务修改刚恢复的新任务。

## 运行与安全

YouTube 是独立的 `MediaTransport.youtube`。Native probe 根据严格校验并规范化的单视频 URL 直接生成视频/音频入口，不在扩展中运行大型解析器。`YouTubeFormatSelection` 只保存格式 ID 与可选音轨 ID；队列保存规范化 watch URL，下载时重新解析。主应用的 `YouTubeDownloader` 调用随包的 yt-dlp/QuickJS 读取 JSON、选择兼容的 H.264/AAC 格式并逐轨下载，FFmpeg 继续只处理本地文件。输出、诊断、超时与取消由 `YouTubeToolProcess` 控制；下载完成后沿用原有 bookmark、独占提交和历史。工具不使用 shell，不读取用户配置/插件或浏览器登录信息。发布的 onedir runtime 以文件夹资源保留 `_internal` 布局，构建时恢复 Python framework 链接、签名库与 sandbox-inheritance 可执行文件。

主 App、两个扩展都有 App Group 和相应 sandbox entitlements；FFmpeg 子进程继承 App sandbox。Safari 状态 API 的 ObjC 回调桥 `App/SafariStateBridge.m` 在调用 Swift 前切回主线程，适配本机 SDK 的后台 XPC 回调行为。

网页数据使用明确模型与输入界限。URL 仅接受 HTTP(S)，header 使用白名单；不会由探针复制浏览器 Cookie/Authorization。HTTP 200 HTML/JSON 被拒绝，避免保存伪媒体文件。DRM/SAMPLE-AES 及直播在解析阶段明确阻止；普通 AES-128 identity 密钥按播放清单处理。日志不记录必要性之外的敏感请求数据。

原生菜单刷新经 SafariBridge 的 siftx-refresh-media DOM 事件重新登记页面，随后发送仅限当前顶层页面的 refresh 消息。后台保留正常观察去重，仅用户刷新设置 forceReanalysis；native 清理该会话候选缓存和播放清单缓存后原子发布结果。资源发布发现后台登记丢失时先重新登记、再补发观察，避免扩展重载后保留旧页面状态。
