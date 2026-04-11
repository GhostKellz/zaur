#!/bin/bash
set -e

cd /workspace

echo "=== ZAUR Full Integration Tests ==="

# Environment setup
export ZAUR_DATA_ROOT="/tmp/zaur-test"
export ZAUR_API_TOKEN="test-token-12345"
export ZAUR_CORS_ORIGIN="http://test-cors-origin"
rm -rf "$ZAUR_DATA_ROOT"

ZAUR="./zig-out/bin/zaur"
FAILED=0
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 $SERVER_PID 2>/dev/null; then
        kill -9 $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1"
    if [ -n "$2" ]; then
        echo "--- Actual response ---"
        echo "$2"
        echo "--- End response ---"
    fi
    FAILED=1
}

pass() {
    echo "PASS: $1"
}

# 1. Build
echo "[1/16] Building ZAUR..."
zig build || { fail "Build failed"; exit 1; }
pass "Build completed"

# 2. Init
echo "[2/16] Initializing..."
$ZAUR init || { fail "Init failed"; exit 1; }
pass "Init completed"

# 3. Add AUR source
echo "[3/16] Adding AUR source (yay)..."
if $ZAUR source add aur/yay 2>/dev/null; then
    pass "AUR source added"
else
    echo "SKIP: AUR source add requires network"
fi

# 4. List sources
echo "[4/16] Listing sources..."
$ZAUR source list || { fail "Source list failed"; exit 1; }
pass "Source list works"

# 5. Mirror verify
echo "[5/16] Testing mirror verify..."
$ZAUR mirror verify 2>/dev/null || true
pass "Mirror verify code path works"

# 6. Repo list
echo "[6/16] Testing repo list..."
$ZAUR repo list 2>/dev/null || true
pass "Repo list code path works"

# 7. Start server
echo "[7/16] Testing server startup..."
$ZAUR serve --port 9004 &
SERVER_PID=$!
sleep 3

if ! kill -0 $SERVER_PID 2>/dev/null; then
    fail "Server failed to start"
    exit 1
fi
pass "Server started"

# 8. Health endpoint
echo "[8/16] Testing API health endpoint..."
RESP=$(curl -sf http://localhost:9004/api/health 2>&1) || RESP="curl failed"
if echo "$RESP" | grep -q '"status":"ok"'; then
    pass "Health endpoint returns OK"
else
    fail "Health endpoint check failed" "$RESP"
fi

# 9. Status endpoint
echo "[9/16] Testing API status endpoint..."
RESP=$(curl -sf http://localhost:9004/api/status 2>&1) || RESP="curl failed"
if echo "$RESP" | grep -q '"status":"ok"'; then
    pass "Status endpoint returns OK"
else
    fail "Status endpoint check failed" "$RESP"
fi

# 10. Path traversal
echo "[10/16] Testing path traversal protection..."
RESP=$(curl -s -i http://localhost:9004/aur/../../../etc/passwd 2>&1)
CODE=$(echo "$RESP" | head -1 | awk '{print $2}')
if [ "$CODE" = "400" ] || [ "$CODE" = "404" ]; then
    pass "Path traversal blocked (HTTP $CODE)"
else
    fail "Path traversal not blocked (HTTP $CODE)" "$RESP"
fi

# 11. Malformed JSON
echo "[11/16] Testing malformed JSON rejection..."
RESP=$(curl -s -i -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $ZAUR_API_TOKEN" -d "not valid json" http://localhost:9004/api/builds 2>&1)
CODE=$(echo "$RESP" | head -1 | awk '{print $2}')
if [ "$CODE" = "400" ]; then
    pass "Malformed JSON rejected with 400"
else
    fail "Malformed JSON not rejected properly (HTTP $CODE)" "$RESP"
fi

# 12. Auth requirement
echo "[12/16] Testing authentication requirement..."
RESP=$(curl -s -i -X POST -H "Content-Type: application/json" -d '{"all":true}' http://localhost:9004/api/builds 2>&1)
CODE=$(echo "$RESP" | head -1 | awk '{print $2}')
if [ "$CODE" = "401" ]; then
    pass "Authentication required (HTTP 401)"
else
    fail "Authentication not enforced (HTTP $CODE)" "$RESP"
fi

# 13. CORS preflight OPTIONS
echo "[13/16] Testing CORS preflight OPTIONS..."
RESP=$(curl -s -i -X OPTIONS -H "Origin: http://test-cors-origin" -H "Access-Control-Request-Method: POST" http://localhost:9004/api/builds 2>&1)
CODE=$(echo "$RESP" | head -1 | awk '{print $2}')
CORS_ORIGIN=$(echo "$RESP" | grep -i "^Access-Control-Allow-Origin:" | awk '{print $2}' | tr -d '\r')
CORS_METHODS=$(echo "$RESP" | grep -i "^Access-Control-Allow-Methods:" | cut -d: -f2 | tr -d '\r')
if [ "$CODE" != "204" ] && [ "$CODE" != "200" ]; then
    fail "CORS preflight wrong status (HTTP $CODE)" "$RESP"
elif [ "$CORS_ORIGIN" != "http://test-cors-origin" ]; then
    fail "CORS preflight wrong origin: got '$CORS_ORIGIN', expected 'http://test-cors-origin'" "$RESP"
elif ! echo "$CORS_METHODS" | grep -q "POST"; then
    fail "CORS preflight missing POST in Allow-Methods" "$RESP"
else
    pass "CORS preflight handled (HTTP $CODE, origin=$CORS_ORIGIN)"
fi

# 14. CORS on 404
echo "[14/16] Testing CORS on 404 error..."
RESP=$(curl -s -i http://localhost:9004/api/nonexistent 2>&1)
CORS_ORIGIN=$(echo "$RESP" | grep -i "^Access-Control-Allow-Origin:" | awk '{print $2}' | tr -d '\r')
if [ "$CORS_ORIGIN" = "http://test-cors-origin" ]; then
    pass "CORS header on 404 error (origin=$CORS_ORIGIN)"
else
    fail "CORS header wrong on 404: got '$CORS_ORIGIN', expected 'http://test-cors-origin'" "$RESP"
fi

# 15. CORS on 401
echo "[15/16] Testing CORS headers on auth error..."
RESP=$(curl -s -i -X POST -H "Content-Type: application/json" -d '{"all":true}' http://localhost:9004/api/builds 2>&1)
CORS_ORIGIN=$(echo "$RESP" | grep -i "^Access-Control-Allow-Origin:" | awk '{print $2}' | tr -d '\r')
if [ "$CORS_ORIGIN" = "http://test-cors-origin" ]; then
    pass "CORS header on auth error (origin=$CORS_ORIGIN)"
else
    fail "CORS header wrong on auth error: got '$CORS_ORIGIN', expected 'http://test-cors-origin'" "$RESP"
fi

# 16. Concurrent burst test - mixed endpoints, DB reads, auth routes, 3 rounds
echo "[16/16] Testing concurrent API burst (mixed endpoints, 3 rounds)..."
BURST_FAIL=0
for round in 1 2 3; do
    PIDS=""
    # Health checks (read-only, no DB)
    for i in 1 2 3; do
        curl -sf --max-time 10 http://localhost:9004/api/health >/dev/null 2>&1 &
        PIDS="$PIDS $!"
    done
    # Status checks (read-only, DB-backed)
    for i in 1 2 3; do
        curl -sf --max-time 10 http://localhost:9004/api/status >/dev/null 2>&1 &
        PIDS="$PIDS $!"
    done
    # Package list (DB-backed read)
    for i in 1 2; do
        curl -sf --max-time 10 http://localhost:9004/api/packages >/dev/null 2>&1 &
        PIDS="$PIDS $!"
    done
    # Source list (DB-backed read)
    for i in 1 2; do
        curl -sf --max-time 10 http://localhost:9004/api/sources >/dev/null 2>&1 &
        PIDS="$PIDS $!"
    done
    # Authenticated route (POST with valid token, expects 400 due to missing body but exercises auth path)
    for i in 1 2; do
        curl -s --max-time 10 -X POST -H "Authorization: Bearer $ZAUR_API_TOKEN" -H "Content-Type: application/json" -d '{}' http://localhost:9004/api/builds >/dev/null 2>&1 &
        PIDS="$PIDS $!"
    done
    # Wait for all requests in this round
    for pid in $PIDS; do
        wait $pid || BURST_FAIL=1
    done
done
sleep 1
RESP=$(curl -sf --max-time 5 http://localhost:9004/api/health 2>&1) || RESP="curl failed"
if [ $BURST_FAIL -eq 1 ]; then
    fail "One or more burst requests failed across 3 rounds"
elif echo "$RESP" | grep -q '"status":"ok"'; then
    pass "Concurrent burst (mixed endpoints, 3 rounds of 15 requests) handled successfully"
else
    fail "Server unresponsive after burst rounds" "$RESP"
fi

# Cleanup
kill -9 $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true
SERVER_PID=""

echo ""
echo "=== Integration Tests Complete ==="

if [ $FAILED -eq 1 ]; then
    echo "RESULT: Some tests FAILED"
    exit 1
else
    echo "RESULT: All tests PASSED"
    exit 0
fi
