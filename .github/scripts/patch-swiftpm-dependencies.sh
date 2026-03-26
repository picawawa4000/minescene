#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TESTVISIBLE_MACRO_FILE="$ROOT_DIR/.build/checkouts/TestVisible/Sources/TestVisiblePlugin/TestVisibleMacro.swift"

if [[ -f "$TESTVISIBLE_MACRO_FILE" ]] && ! grep -Fq "import Foundation" "$TESTVISIBLE_MACRO_FILE"; then
  chmod u+w "$TESTVISIBLE_MACRO_FILE"
  python3 - "$TESTVISIBLE_MACRO_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "import SwiftDiagnostics\n"
if marker not in text:
    raise SystemExit(f"Could not find insertion point in {path}")
path.write_text(text.replace(marker, marker + "import Foundation\n", 1))
PY
  echo "Patched TestVisible to import Foundation."
fi
