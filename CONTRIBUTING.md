# 参与开发 SiftX

感谢提交改进。请尽量让每个 PR 聚焦一个主题，并描述用户可见行为与测试证据。

## 代码结构

- `Sources/SiftXCore/`：共享模型、媒体分析、HLS/DASH、URL/文件安全和持久化。
- `App/`：SwiftUI 主程序、下载引擎与设置。
- `SafariExtension/`：原生 Safari 扩展、工具栏和媒体预览。
- `MediaProbe/`：Web Extension 的网页观测、会话隔离和原生消息转发。
- `Tests/`：Swift Package 单元测试、原生下载集成测试、Node 探针测试和 Python 配置测试。
- `Scripts/`：项目生成、fixture 生成、打包及第三方资源构建。

## 提交前检查

1. 根据改动添加/更新对应回归测试。纯媒体解析用本地数据，Safari 探针用 Node 模拟会话；不要把真实网站作为可靠测试输入。
2. 运行 [测试指南](docs/TESTING.md) 中适用的测试，标注通过、失败和跳过的项目。
3. 若改变了功能、最低系统要求、权限或配置，同步更新 README / 测试指南。
4. 如果修改 Xcode 工程定义，优先更新 `Scripts/generate_project.py` 再重新生成 `SiftX.xcodeproj`，不要只改生成后的 pbxproj。
5. 不提交 `Build/`、DerivedData、签名凭据、浏览器 Cookie、私人媒体或第三方登录信息。

## 提交 PR

在说明中写明动机、主要改动、复现步骤和测试命令。涉及 GUI 时可附截图；涉及 Safari 或本地下载时说明已覆盖的平台与尚未手动验证的行为。CI 通过不意味着扩展在 Safari 中已完成实机验收。

## 依赖与版权

涉及 FFmpeg、yt-dlp、QuickJS 或其他第三方代码的变更，需要核对并更新 [THIRD_PARTY.md](THIRD_PARTY.md) 及 [ThirdParty/README.md](ThirdParty/README.md) 所述清单、许可和源码交付要求。只使用本人拥有权利或已获授权的媒体进行测试。
