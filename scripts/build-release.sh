#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p .tmp/go-tmp .tmp/go-cache .tmp/tmp
export GOTMPDIR="$root/.tmp/go-tmp" GOCACHE="$root/.tmp/go-cache" TMPDIR="$root/.tmp/tmp"
rm -rf .tmp/dist
mkdir -p .tmp/dist

for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64; do
  os=${target%/*}
  arch=${target#*/}
  name="adb-lease-guard-${os}-${arch}"
  [[ "$os" != windows ]] || name+=.exe
  CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go build -trimpath -ldflags='-s -w' \
    -o ".tmp/dist/$name" ./cmd/guard
done
cp install.sh install.ps1 .tmp/dist/
(
  cd .tmp/dist
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum adb-lease-guard-* install.sh install.ps1 > SHA256SUMS
  else
    shasum -a 256 adb-lease-guard-* install.sh install.ps1 > SHA256SUMS
  fi
)
printf 'Release assets: %s\n' "$root/.tmp/dist"
