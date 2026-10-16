#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${1:-iphoneos}"
ARCH="${2:-arm64}"
case "$SDK" in
 iphoneos) TARGET="$ARCH-apple-ios26.0" ;;
 iphonesimulator) TARGET="$ARCH-apple-ios26.0-simulator" ;;
 *) echo 'Usage: build-core.sh [iphoneos|iphonesimulator] [arm64|x86_64]' >&2; exit 2 ;;
esac
GO_ARCH="$ARCH"
if [ "$ARCH" = x86_64 ]; then GO_ARCH=amd64; fi
SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
mkdir -p "$TASK_ROOT/build/core/$SDK-$ARCH"
cd "$TASK_ROOT/mobile"
CGO_ENABLED=1 GOOS=ios GOARCH="$GO_ARCH" CC="$(xcrun --sdk "$SDK" --find clang)" \
 CGO_CFLAGS="-target $TARGET -isysroot $SDK_PATH" \
 CGO_LDFLAGS="-target $TARGET -isysroot $SDK_PATH" \
 go build -trimpath -buildmode=c-archive -o "$TASK_ROOT/build/core/$SDK-$ARCH/libCameraCore.a" ./bridge
