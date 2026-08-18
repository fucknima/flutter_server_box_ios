#!/bin/sh
# Pre-push validation for native-ios Swift sources.
# Run before pushing: scripts/check.sh
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== swiftc -parse =="
for f in $(find ServerBox Shared StatusWidget ServerBoxTests -name "*.swift"); do
    swiftc -parse "$f"
done
echo "parse OK"

echo "== brace balance =="
for f in $(find ServerBox Shared StatusWidget -name "*.swift"); do
    open=$(grep -o "{" "$f" | wc -l)
    close=$(grep -o "}" "$f" | wc -l)
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
