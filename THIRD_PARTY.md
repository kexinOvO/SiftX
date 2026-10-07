# Third-party components and source materials

The pinned offline source inventory is in [ThirdParty/README.md](ThirdParty/README.md), with versions, original URLs, hashes and license summaries in [sources.lock.json](ThirdParty/sources.lock.json). Original archives are retained in `ThirdParty/Sources/`; source correspondence is documented in [PROVENANCE.md](ThirdParty/PROVENANCE.md), and reproduction/integration instructions in [BUILDING.md](ThirdParty/BUILDING.md).

`python3 Scripts/prepare_third_party.py --fetch` verifies the audited runtime and downloads only missing pinned source archives, then generates `Build/Distribution/SiftX-ThirdParty-Sources.zip`. `sh Scripts/build_release.sh` includes complete notices in the application and packages the signed app together with this source ZIP. Publish the resulting `SiftX-<version>-<build>-macOS-arm64.zip` with its checksum. If offering a separate app download, also offer the matching source ZIP at the same version's download location, at no additional charge.

Application resources retain original component notices plus `ThirdParty-LICENSES.txt` and `ThirdParty-SOURCE-NOTICE.txt`. The source ZIP contains the full original archives, extracted root license texts, upstream locks/build files, SiftX integration scripts and per-file SHA-256 checksums. Third-party works remain under their upstream licenses; this document does not select a license for SiftX's own source.

## Media processor

SiftX executes FFmpeg as a separate local process to remux downloaded ordinary media into playable MP4/M4A files. The application does not link FFmpeg libraries into Swift targets.

- Upstream: [FFmpeg](https://ffmpeg.org/)
- Version: 7.1.1
- Source archive: `ThirdParty/Sources/ffmpeg-7.1.1.tar.xz` (the original archive also remains in `ThirdParty/ffmpeg-7.1.1.tar.xz`).
- SHA-256: `733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1`
- License of this configuration: LGPL 2.1 or later, reproduced in `App/Resources/FFmpeg-LICENSE.txt`.
- Reproduction: `sh Scripts/build_media_tool.sh` with Apple command-line tools.
- Source modifications: none. Configure flags are recorded in the build script and `ffmpeg -version`.
- Deployment: arm64, macOS 14 minimum. Links only system libraries/frameworks.

The CLI is replaceable with a compatible FFmpeg build. When redistributing SiftX, retain license notices and provide the corresponding FFmpeg source and reproduction script along with the binary. Signing a replacement for sandbox inheritance is required by macOS; use the same signing identity and `Config/MediaTool.entitlements`.

Network protocols, decryption and external codec libraries are disabled in the bundled build. Media data is fetched and validated by the native download engine. Most operations copy compressed audio/video without re-encoding.

## Media parser tools

Media parsing runs in a separate bundled process; the existing FFmpeg processor handles its local outputs.

- yt-dlp **2026.08.19**, official `yt-dlp_macos.zip` (onedir distribution): [release and source](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19).
- Archive SHA-256: `07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8`, checked against the upstream `SHA2-256SUMS` release asset.
- QuickJS-NG **0.17.0**, official `qjs-darwin-arm64`: [release and source](https://github.com/quickjs-ng/quickjs/releases/tag/v0.17.0).
- QuickJS binary SHA-256: `8be3ddfe3397d2e692e4e1e8972ee9d032a0a580505d2f8b4ea528cf1b651c11`.
- The tools live in `App/Resources/YouTubeTools/`. `Scripts/fetch_youtube_tools.py` reproduces the downloads, verifies pinned digests, removes unused x86_64 slices, and restores the versioned Python framework links flattened in the release ZIP.
- `Scripts/sign_youtube_tools.py` signs native libraries/frameworks and gives only the yt-dlp/qjs executables sandbox-inheritance entitlements. The onedir executable avoids the onefile bootloader's System V semaphore requirement, which App Sandbox rejects.
- yt-dlp source is Unlicense; its official PyInstaller distribution includes components covered by GPLv3+ and other licenses. Upstream notices and source links are retained in `App/Resources/YouTube-THIRD-PARTY-LICENSES.txt` (also inside the runtime) and `yt-dlp-LICENSE.txt`. Exact dependency versions and source archives are recorded in `ThirdParty/sources.lock.json`. QuickJS-NG's MIT notice is in `App/Resources/QuickJS-LICENSE.txt`. Retain these notices and the corresponding offline source package when redistributing.
- User configuration, plugins, browser cookies, and remote component installation are disabled. The bundled EJS scripts use the bundled QuickJS runtime; no auto-update is performed at runtime. Update the pinned versions and hashes in the fetch script when releasing a compatibility update.

## Parser runtime and build inputs

The source package includes Python 3.14.6, OpenSSL 3.5.7, zstd 1.5.7, mutagen 1.48.1 (GPL-2.0-or-later), PyInstaller 6.22.0 and its bootloader exception, and pinned Python package sources from the same yt-dlp release's macOS requirements. curl-cffi 0.16.0 sources pin curl-impersonate 2.0.0; that source tree contains curl patches and SHA-256-pinned curl 8.21.0/BoringSSL/compression/HTTP-library sources, all supplied in the package. yt-dlp-ejs 0.8.0 source includes its TypeScript and package locks; Meriyah 6.1.4 and Astring 1.9.0 sources are also included.

Build-only inputs are labelled separately. The upstream aggregate notices cover several platforms, while this inventory targets the shipped macOS arm64 resources. Source provenance records which versions were observed locally and which follow upstream locks. Updating a runtime component requires updating its sources, notices and `runtime-files.json` before the release checks pass.
