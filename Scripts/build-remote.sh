#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/Resources/remote"
cd "$ROOT/Remote"
for os in darwin linux; do
  for arch in amd64 arm64; do
    echo "Building peek-$os-$arch"
    CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go build -trimpath -ldflags='-s -w' -o "$ROOT/Resources/remote/peek-$os-$arch" .
  done
done
