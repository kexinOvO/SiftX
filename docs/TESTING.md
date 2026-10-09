# SiftX 测试指南

SiftX 包含可以离线执行的核心测试，以及需要 macOS/Xcode、本地媒体和 HTTP 服务器的集成测试。**不要把未执行的测试记录为已通过**。

## 测试矩阵

| 套件 | 覆盖内容 | 环境 | 命令 |
| --- | --- | --- | --- |
| SiftXCoreTests | URL 安全、文件名、HLS/DASH、AES-128、持久化、Bilibili/YouTube 格式解析 | macOS + Swift 6 | `swift test` |
| SafariExtensionStateTests | 工具栏角标、会话状态 | macOS + Swift 6 | `swift test` |
| MediaPreviewTests | 本地代理、播放/音轨；需本地服务才能运行集成项 | macOS + Swift 6 + 可选 fixtures | `swift test` |
| ProbeTests | 资源分类、去重、页面会话隔离、消息桥接、边界数据 | Node.js 22+ | `node --test Tests/ProbeTests/*.test.cjs` |
| ConfigurationTests | Safari plist/manifest、脚本存在性、App Group、测试 scheme | Python 3.11+ | `python3 -m unittest discover -s Tests/ConfigurationTests -p 'test_*.py'` |
| DownloadTests | HTTP Range、续传、取消/重试、HLS/DASH/AES-128、视频合并与历史记录 | Apple Silicon macOS + Xcode + fixtures | `xcodebuild ... test` |

CI 在 PR 和 main push 时运行 JavaScript、Python 和 Swift Package 测试。**CI 不运行完整的原生下载端到端测试，也不等同于 Safari 实机验收。**

## 快速执行（macOS）

需要 Swift 6（可通过 Xcode Command Line Tools 提供）、Node.js 22+、Python 3.11+。在仓库根目录：

```sh
sh Scripts/test.sh
```

也可以只运行需要的部分：

```sh
swift test
swift test --filter SafetyEdgeCaseTests
node --test Tests/ProbeTests/*.test.cjs
python3 -m unittest discover -s Tests/ConfigurationTests -p 'test_*.py'
```

Swift Package 测试不需要开发者签名。未设置 `SIFTX_PREVIEW_FIXTURE_BASE_URL` 时，依赖本地 HTTP 服务的预览测试会显式跳过，不能算通过。由于核心 Swift 依赖 Apple 平台框架，**不要在 Linux 上运行 `swift test`**；Linux CI 只执行 JavaScript/Python。

## 下载与预览的本地集成测试

需要 Apple Silicon Mac、Xcode、含 `libx264` 和 `libmp3lame` 的完整 FFmpeg、OpenSSL。下载套件使用仓库内的 `App/Resources/ffmpeg` 作为媒体合并工具。准备过程中只生成仓库自制的合成媒体，不访问第三方视频网站。

1. 生成测试媒体：
   ```sh
   python3 Scripts/make_fixtures.py
   ```
2. 在终端 A 启动测试服务器（保持运行）：
   ```sh
   python3 Scripts/fixture_server.py --port 18765
   ```
3. 在终端 B 跑原生下载测试：
   ```sh
   xcodebuild -project SiftX.xcodeproj -scheme SiftX -configuration Debug \
     -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath Build/DerivedData CODE_SIGNING_ALLOWED=NO test
   ```
4. 可选：启用真实本地资源，运行预览集成测试：
   ```sh
   SIFTX_PREVIEW_FIXTURE_BASE_URL=http://127.0.0.1:18765 swift test --filter MediaPreviewTests
   ```

`SIFTX_FIXTURE_BASE_URL` 可覆盖下载套件的 HTTP 基址，默认 `http://127.0.0.1:18765`。本地服务器支持 HTTP 206/错误 Range、401/403、响应截断、Referer、加密片段等回归场景。测试使用本地临时目录存储下载，不应指向真实下载资料目录。

## 手工 Safari 验收（不属于 CI）

在签名并安装适用的 App 与两个扩展后，检查以下流程：

- 在 Safari 设置中启用 SiftX Safari Extension 和 SiftX Media Probe，按需授予网站访问权限。
- 使用本地测试页面播放 MP4、MP3、HLS/DASH，确认工具栏扫描、媒体筛选、角标及预览。
- 将媒体加入下载队列，确认暂停、恢复、重试、文件保存与历史记录。
- 验证权限被拒、资源失效、加密/不支持媒体时的错误提示；测试 Safari 标签切换、关闭和隐私窗口。

不要使用有版权限制或未经许可的网站作为自动化测试依赖。既往人工验收记录见 [VERIFICATION.md](../VERIFICATION.md)；其中的历史结果不代表当前分支已重新测试。

## 常见问题

- **`swift test` 提示缺少 Apple 框架**：确认运行于 macOS，执行 `xcode-select -p` 查看工具链。
- **集成测试报连接拒绝**：确认 fixture 服务器已在端口 18765 监听，且已先生成 `Build/Fixtures`。
- **fixture 生成失败**：确认 `ffmpeg` 可执行且支持所需编码器，以及 `openssl` 在 PATH。
- **原生构建或签名失败**：仅运行 Swift Package 测试通常不需签名。Safari 实机检查需要开发者证书、App Group 和扩展权限；不要向仓库提交个人签名资料。

若修改了 `Scripts/generate_project.py`、Xcode target 或 scheme，应重新生成工程并验证对应测试 target。
