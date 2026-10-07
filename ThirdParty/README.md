# 第三方源码与发布材料

Last reviewed: 2026-10-07

本目录保留 SiftX macOS arm64 随包工具的固定版本源码。`sources.lock.json` 记录每份归档的原始 URL、SHA-256、版本、许可摘要和取证依据；`Sources/` 是未修改的上游源码归档。完整许可条款以各源码和 notice 原文为准。

## 获取和打包

```sh
python3 Scripts/prepare_third_party.py --fetch
```

缺失源码从清单中的固定 URL 获取，并在写入前核对 SHA-256；已有文件不被自动替换。生成 `Build/Distribution/SiftX-ThirdParty-Sources.zip` 和其校验文件。已有全部源码时无需网络。

```sh
python3 Scripts/prepare_third_party.py --verify-only
sh Scripts/build_release.sh
```

Release 构建会先验证源码及原始运行时文件，加入完整许可证和源码获取说明，再生成 `Build/Distribution/SiftX-<版本>-<构建号>-macOS-arm64.zip`。该分发包内同时放置 `SiftX.app` 和离线源码包。直接打包已有应用可用 `python3 Scripts/package_distribution.py`；过期或缺少 notice 的应用会被拒绝，应用内工具须与清单一致。原生文件使用临时副本统一签名元数据后逐字节比较；资源复制禁用自动 strip，以保留已核对的第三方可执行文件。

## 再分发

- 发布完整分发 ZIP，并保留其中源码包、许可说明和校验文件。
- 若另提供单独 `.app`、DMG 或应用 ZIP，在同版本下载位置同时免费提供匹配的源码 ZIP，保持访问方式清晰。普通项目主页链接不替代对应材料。
- 本包包含 FFmpeg 的 LGPL 源码、yt-dlp 发行源码及原仓库构建文件、GPL 组件 mutagen 的源码、PyInstaller 源码及 bootloader exception、Python 和随包原生依赖源码、QuickJS-NG 源码。
- 标为 `build` 的工具作为构建输入收录；不表示每个构建工具都随应用运行。聚合 notice 同时覆盖多个平台，macOS 实际范围见 [PROVENANCE.md](PROVENANCE.md)。
- 本目录中的第三方源码沿用上游许可证；项目自身代码的许可证应单独确定。

## 更新组件

更新二进制时，先核对版本、官方校验值、macOS requirements 和原生依赖，取得匹配源码并更新 `sources.lock.json`、`Upstream/` 和 `runtime-files.json`。`runtime-files.json` 是构建前的完整文件/符号链接清单；Xcode 在应用副本中签名。更新后重新生成源码包与应用，检查最终 ZIP 中的源码、许可证和校验值。

源码包内有 `INDEX.md` 和 `SHA256SUMS`；`ThirdParty/BUILDING.md` 说明构建路径和本项目对上游二进制的处理。
