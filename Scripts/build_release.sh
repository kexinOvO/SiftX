#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
if [ ! -x App/Resources/YouTubeTools/yt-dlp ] || [ ! -x App/Resources/YouTubeTools/qjs ]; then
  python3 Scripts/fetch_youtube_tools.py
fi
python3 Scripts/prepare_release_products.py
python3 Scripts/generate_project.py
xcodebuild -project SiftX.xcodeproj -scheme SiftX -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath Build/DerivedData -clonedSourcePackagesDirPath Build/Packages \
  CONFIGURATION_BUILD_DIR="$task_root/Build" build
codesign --verify --deep --strict Build/SiftX.app
