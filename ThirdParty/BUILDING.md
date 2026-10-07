# Build and integration instructions

Last reviewed: 2026-10-07

The source package preserves original upstream archives. Unpack the archive named in `sources.lock.json`; each archive retains its own license and nested third-party notices. `runtime-files.json` identifies the pre-Xcode resources these materials accompany. Build-only inputs are labelled separately in the source manifest. Exact binary byte reproduction is not asserted: compiler/SDK versions, timestamps, generated release metadata and Apple signing can differ.

## FFmpeg 7.1.1

Use Apple command-line tools on arm64 macOS. `Scripts/build_media_tool.sh` verifies and uses `ThirdParty/Sources/ffmpeg-7.1.1.tar.xz`, then runs the recorded configure command and `make`. Source modifications: none. The build disables network, autodetected external libraries and most codecs; Swift invokes the separate executable. The script writes the executable and LGPL notice into `App/Resources`.

## yt-dlp 2026.08.19 and its onedir runtime

Two archives are supplied: the upstream release `yt-dlp.tar.gz`, including generated release files, and the tag's repository tree, including `bundle/pyinstaller.py`, PyInstaller hooks, devscripts and `.github/workflows/build.yml`. The workflow and its macOS requirements locks are additionally copied into `ThirdParty/Upstream` for convenient reference.

The official macOS build workflow uses a Python virtual environment, installs its pinned macOS wheels, merges the arm64 and x86_64 curl-cffi/cffi wheels with delocate, runs `devscripts/update-version.py` and `devscripts/make_lazy_extractors.py`, then runs:

```sh
python3 -m bundle.pyinstaller --target-architecture universal2 --onedir
```

Use Python 3.14.6 and the supplied exact-version source archives/requirements locks for the relevant components. Install the dependencies in a dedicated virtual environment; the authoritative upstream commands and platform conditions are in `ThirdParty/Upstream/yt-dlp-build.yml`. The PyInstaller archive includes its bootloader source, COPYING and exception. `mutagen` carries GPL-2.0-or-later, while the official combined executable is described by yt-dlp as GPLv3+. Its original notices and a full GPLv3 text are retained.

SiftX does not patch yt-dlp or dependency source. `Scripts/fetch_youtube_tools.py` downloads and verifies the pinned official onedir ZIP, renames `yt-dlp_macos` to `yt-dlp`, removes x86_64 Mach-O slices with `lipo`, restores the Python framework symbolic links through `normalize_youtube_tools.py` and adds the pinned QuickJS-NG binary. `sign_youtube_tools.py` signs the copied resources during Xcode builds with the project's macOS sandbox entitlements. `COPY_PHASE_STRIP=NO` preserves third-party resources during copying. All these integration scripts and the entitlements are in the source package. No upstream implementation patch is applied.

## CPython, OpenSSL and zstd

The runtime's Python.framework identifies Python 3.14.6; `Python-3.14.6.tar.xz` includes `Mac/BuildScript/build-installer.py` and the CPython build/install sources. OpenSSL 3.5.7 and zstd 1.5.7 source archives accompany the packaged dylibs. Apple system libraries/frameworks are supplied by macOS, rather than redistributed as separate SiftX libraries. See the provenance file for the evidence and limits of matching the official runtime.

## curl-cffi and native dependencies

curl-cffi 0.16.0's `scripts/build.py` pins curl-impersonate 2.0.0. The latter archive includes CMake build instructions and curl patches; its `CMakeLists.txt` pins curl 8.21.0 and native dependencies by URL and SHA-256. Every one of those native source inputs is included, including BoringSSL at the exact pinned commit. Follow `INSTALL.md` and `CMakeLists.txt` from the curl-impersonate archive. Retain the patches when building curl; the plain curl archive alone does not represent the impersonation build.

For yt-dlp-ejs, the source distribution includes TypeScript and lockfiles. Meriyah and Astring are additionally supplied as original editable repository source archives at the matching tags, alongside the exact npm package archives whose integrity hashes match its `package-lock.json`. Follow its package/build scripts to regenerate the JavaScript bundle.

## QuickJS-NG 0.17.0

The tag archive includes the MIT license, CMakeLists.txt and upstream build documentation. With a C compiler and CMake on arm64 macOS, follow its README build instructions (`cmake -S . -B build`, then `cmake --build build`). SiftX uses the official `qjs-darwin-arm64` release executable unchanged apart from Apple signing of the application copy.

## Replaceability

FFmpeg and the parser tools are separate executables; compatible replacements can be built from the supplied sources. A replacement inside a signed app must be signed with the appropriate macOS inheritance entitlements and the outer app signed again. Keep the framework symlinks and onedir layout. License terms grant rights in each third-party component independently; a redistribution agreement must preserve those rights.
