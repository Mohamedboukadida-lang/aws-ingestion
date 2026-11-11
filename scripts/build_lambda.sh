#!/usr/bin/env bash
# Build a Lambda zip for the given package under src/ using the Lambda runtime's Python.
set -euo pipefail
cd "$(dirname "$0")/.."
pkg="${1:?usage: build_lambda.sh <package>}"
out="build/${pkg}"
rm -rf "$out" && mkdir -p "$out"
uv export --no-dev --no-hashes --no-emit-project > "build/${pkg}.requirements.txt"
uv pip install --python 3.13 --target "$out" -r "build/${pkg}.requirements.txt" --quiet
cp -r "src/${pkg}" "$out/"
echo "built $out"
