#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TASK_ROOT/build"
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" "$TASK_ROOT/ios/AlphaRemote/Models.swift" "$TASK_ROOT/ios/AlphaRemote/ExportModels.swift" "$TASK_ROOT/ios/AlphaRemote/ExportStore.swift" "$TASK_ROOT/ios/AlphaRemote/ViewfinderGeometry.swift" "$TASK_ROOT/tests/ExportLogicTests.swift" -o "$TASK_ROOT/build/export-logic-tests"
"$TASK_ROOT/build/export-logic-tests"
