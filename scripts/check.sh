#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT/mobile"
go test -race ./...
go vet ./...
cd "$TASK_ROOT/prototype"
go test -race ./...
cd "$TASK_ROOT/vendor/alpha2go"
go test ./...
cd "$TASK_ROOT"
/usr/bin/python3 -m py_compile scripts/generate-project.py scripts/import-local-access.py scripts/profile-expiry.py
bash -n scripts/build-core.sh scripts/install-device.sh

"$TASK_ROOT/scripts/test-export-logic.sh"
