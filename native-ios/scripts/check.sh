#!/bin/sh
# Pre-push validation for native-ios Swift sources.
# Run before pushing: scripts/check.sh
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SWIFTC="${SWIFTC:-/opt/swift/usr/bin/swiftc}"
if [ ! -x "$SWIFTC" ]; then
    echo "swiftc not found at $SWIFTC (set SWIFTC)"
    exit 1
fi

echo "== swiftc -parse =="
for f in $(find ServerBox Shared StatusWidget ServerBoxTests -name "*.swift"); do
    "$SWIFTC" -parse "$f"
done
echo "parse OK"

echo "== parse OK =="
if grep -rn "SSHStatusProtocol" ServerBox ServerBoxTests --include="*.swift"; then
    echo "SSHStatusProtocol was removed; fix references"
    exit 1
fi
echo "references OK"

echo "ALL CHECKS PASSED"
