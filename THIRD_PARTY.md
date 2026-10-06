# Third-party media processor

SiftX executes FFmpeg as a separate local process to remux downloaded ordinary media into playable MP4/M4A files. The application does not link FFmpeg libraries into Swift targets.

- Upstream: [FFmpeg](https://ffmpeg.org/)
- Version: 7.1.1
- Source archive: `ThirdParty/ffmpeg-7.1.1.tar.xz`
- SHA-256: `733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1`
- License of this configuration: LGPL 2.1 or later, reproduced in `App/Resources/FFmpeg-LICENSE.txt`.
- Reproduction: `sh Scripts/build_media_tool.sh` with Apple command-line tools.
- Source modifications: none. Configure flags are recorded in the build script and `ffmpeg -version`.
- Deployment: arm64, macOS 14 minimum. Links only system libraries/frameworks.

The CLI is replaceable with a compatible FFmpeg build. When redistributing SiftX, retain license notices and provide the corresponding FFmpeg source and reproduction script along with the binary. Signing a replacement for sandbox inheritance is required by macOS; use the same signing identity and `Config/MediaTool.entitlements`.

Network protocols, decryption and external codec libraries are disabled in the bundled build. Media data is fetched and validated by the native download engine. Most operations copy compressed audio/video without re-encoding.

## YouTube tools

YouTube extraction and per-track downloads run in a separate bundled process; SiftX remuxes its local outputs with the existing FFmpeg processor.

- yt-dlp **2026.08.19**, official `yt-dlp_macos.zip` (onedir distribution): [release and source](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19).
- Archive SHA-256: `07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8`, checked against the upstream `SHA2-256SUMS` release asset.
- QuickJS-NG **0.17.0**, official `qjs-darwin-arm64`: [release and source](https://github.com/quickjs-ng/quickjs/releases/tag/v0.17.0).
- QuickJS binary SHA-256: `8be3ddfe3397d2e692e4e1e8972ee9d032a0a580505d2f8b4ea528cf1b651c11`.
- The tools live in `App/Resources/YouTubeTools/`. `Scripts/fetch_youtube_tools.py` reproduces the downloads, verifies pinned digests, removes unused x86_64 slices, and restores the versioned Python framework links flattened in the release ZIP.
- `Scripts/sign_youtube_tools.py` signs native libraries/frameworks and gives only the yt-dlp/qjs executables sandbox-inheritance entitlements. The onedir executable avoids the onefile bootloader's System V semaphore requirement, which App Sandbox rejects.
- yt-dlp source is Unlicense; its official PyInstaller distribution includes components licensed under GPLv3+ and other licenses. Upstream notices, dependency versions and source links are retained in `App/Resources/YouTube-THIRD-PARTY-LICENSES.txt` (also present inside the runtime), and `yt-dlp-LICENSE.txt`. QuickJS-NG's MIT notice is in `App/Resources/QuickJS-LICENSE.txt`. Retain these notices and satisfy the bundled components' corresponding-source requirements when redistributing.
- User configuration, plugins, browser cookies, and remote component installation are disabled. The bundled EJS scripts use the bundled QuickJS runtime; no auto-update is performed at runtime. Update the pinned versions and hashes in the fetch script when releasing a compatibility update.
