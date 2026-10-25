#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${FRIJA_BUILD_DIR:-$project_dir/.build}"
module_dir="$build_dir/module-cache"
framework_dir="$(xcode-select -p)/Library/Developer/Frameworks"
mkdir -p "$module_dir"
export CLANG_MODULE_CACHE_PATH="$module_dir"
swift test --package-path "$project_dir" --scratch-path "$build_dir/tests" \
    --build-system native --disable-sandbox \
    -Xswiftc -module-cache-path -Xswiftc "$module_dir" \
    -Xswiftc -F -Xswiftc "$framework_dir" \
    -Xlinker -rpath -Xlinker "$framework_dir"
