# Source provenance

Last reviewed: 2026-10-07

This inventory accompanies the current macOS arm64 resources. URLs and SHA-256 values are frozen in `sources.lock.json`; the source ZIP also contains a checksum for every included file. Original source archives are not rewritten.

| Material | Matching evidence |
| --- | --- |
| FFmpeg 7.1.1 | Bundled `-version` output and configure flags match `Scripts/build_media_tool.sh`; source digest matches the existing recorded upstream archive. Only Apple system libraries/frameworks are dynamically linked. |
| yt-dlp 2026.08.19 | Bundled `--version`; official macOS ZIP digest in the fetch script; source release tar digest matched against upstream `SHA2-256SUMS`. The tag repository supplies upstream build scripts and pinned requirements. |
| Python dependencies | Versions pinned by the same yt-dlp tag's macOS requirements, with platform-only alternatives excluded. curl-cffi 0.16.0 and websockets 17.0.1 also have bundled dist-info metadata. Each PyPI source digest matches its version-specific PyPI metadata. |
| CPython 3.14.6 | Version in bundled Python.framework Info.plist. The archive is the matching python.org source release. |
| OpenSSL 3.5.7 | Version string in packaged libcrypto/libssl. The archive is the matching upstream release. |
| zstd 1.5.7 | Packaged libzstd dylib version and the curl-impersonate native source lock. |
| curl-impersonate 2.0.0 | curl-cffi 0.16.0 source build script pins this release; its curl 8.21.0 matches the packaged extension's `8.21.0-IMPERSONATE` banner. Patches and native dependency source archives are included; hashes match its CMake source lock. |
| Meriyah 6.1.4 / Astring 1.9.0 | yt-dlp-ejs 0.8.0 package-lock URLs and integrity hashes for the npm archives, plus original editable repository sources at the corresponding version tags. |
| QuickJS-NG 0.17.0 | Bundled version output and fixed official binary hash in `fetch_youtube_tools.py`; matching upstream tag source. |

The yt-dlp notice aggregates several platforms. Windows OpenSSL 1.x and Linux GNU readline/libintl/libidn2/libunistring/GCC runtime notices do not imply those libraries are bundled in this macOS build. The macOS native scan found packaged Python.framework, libcrypto.3.dylib, libssl.3.dylib, libzstd.1.dylib and package extension modules. Their external links resolve to Apple system libraries or these package-local libraries. curl-cffi embeds its curl implementation inside its extension.

The supplied upstream sources and build scripts document source correspondence and build inputs. Upstream's official artifact does not include its full local compiler/linker map or a bit-for-bit build attestation. Versions inferred from an upstream lock are distinguished from locally observed metadata above; no claim of byte-identical reconstruction is made. SiftX's source-resource hashes freeze the audited runtime so a tool replacement requires a fresh source review.
