#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${FRIJA_BUILD_DIR:-$project_dir/.build}"
CARGO_TARGET_DIR="$build_dir/rust-tests" cargo test --manifest-path "$project_dir/Backend/Cargo.toml" --locked --workspace --features mock
bash "$project_dir/scripts/test.sh"
