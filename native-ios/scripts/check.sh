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

echo "== brace balance =="
for f in $(find ServerBox Shared StatusWidget -name "*.swift"); do
    stripped=$(sed -e 's/"[^"]*"//g' "$f")
    open=$(echo "$stripped" | grep -o "{" | wc -l)
    close=$(echo "$stripped" | grep -o "}" | wc -l)
    if [ "$open" != "$close" ]; then
        echo "UNBALANCED: $f ($open vs $close)"
        exit 1
    fi
done
echo "braces OK"

echo "== stale protocol references =="
if grep -rn "SSHStatusProtocol" ServerBox ServerBoxTests --include="*.swift"; then
    echo "SSHStatusProtocol was removed; fix references"
    exit 1
fi
echo "references OK"

echo "ALL CHECKS PASSED"
