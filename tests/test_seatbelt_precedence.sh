#!/usr/bin/env bash
# Test Seatbelt rule precedence for allow vs deny
# Determines whether first-match or last-match wins
#
# FINDING: Seatbelt uses LAST-MATCH-WINS semantics.
# To allow a subpath inside a denied parent:
#   1. (deny ... parent)
#   2. (allow ... child)  <-- must come AFTER the deny

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "SKIP: Seatbelt tests only run on macOS"
	exit 0
fi

echo "=== Seatbelt Rule Precedence Test ==="
echo "macOS version: $(sw_vers -productVersion)"
echo "Architecture: $(uname -m)"
echo ""

# Setup test directory
TEST_DIR="$HOME/.seatbelt_precedence_test_$$"
mkdir -p "$TEST_DIR/parent/child"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "child_content" >"$TEST_DIR/parent/child/file.txt"
echo "sibling_content" >"$TEST_DIR/parent/sibling.txt"

PARENT_PATH="$TEST_DIR/parent"
CHILD_PATH="$TEST_DIR/parent/child"

PASSED=0
FAILED=0

pass() {
	echo "PASS: $1"
	PASSED=$((PASSED + 1))
}
fail() {
	echo "FAIL: $1"
	FAILED=$((FAILED + 1))
}

echo "Test paths:"
echo "  Parent: $PARENT_PATH"
echo "  Child:  $CHILD_PATH"
echo ""

#
# Test 1: Baseline - deny parent blocks everything under it
#
echo "--- Test 1: Deny parent blocks child (baseline) ---"
POLICY=$(mktemp)
cat >"$POLICY" <<EOF
(version 1)
(allow default)
(deny file-read* (subpath "$PARENT_PATH"))
EOF

if sandbox-exec -f "$POLICY" cat "$CHILD_PATH/file.txt" 2>/dev/null; then
	fail "Deny parent should block child read"
else
	pass "Deny parent blocks child read"
fi
rm -f "$POLICY"

#
# Test 2: Allow child THEN deny parent - child should be DENIED (last match wins)
#
echo ""
echo "--- Test 2: Allow child THEN deny parent (wrong order) ---"
POLICY=$(mktemp)
cat >"$POLICY" <<EOF
(version 1)
(allow default)
(allow file-read* (subpath "$CHILD_PATH"))
(deny file-read* (subpath "$PARENT_PATH"))
EOF

if sandbox-exec -f "$POLICY" cat "$CHILD_PATH/file.txt" 2>/dev/null; then
	fail "Wrong order: child should be denied when deny comes after allow"
else
	pass "Wrong order: child correctly denied (last match wins)"
fi
rm -f "$POLICY"

#
# Test 3: Deny parent THEN allow child - child should be ALLOWED (last match wins)
#
echo ""
echo "--- Test 3: Deny parent THEN allow child (correct order) ---"
POLICY=$(mktemp)
cat >"$POLICY" <<EOF
(version 1)
(allow default)
(deny file-read* (subpath "$PARENT_PATH"))
(allow file-read* (subpath "$CHILD_PATH"))
EOF

if output=$(sandbox-exec -f "$POLICY" cat "$CHILD_PATH/file.txt" 2>/dev/null) && [[ "$output" == "child_content" ]]; then
	pass "Correct order: child allowed (last match wins)"
else
	fail "Correct order: child should be allowed when allow comes after deny"
fi

# Verify sibling is still denied
if sandbox-exec -f "$POLICY" cat "$PARENT_PATH/sibling.txt" 2>/dev/null; then
	fail "Sibling should still be denied"
else
	pass "Sibling correctly denied"
fi
rm -f "$POLICY"

#
# Test 4: Same test for file-write*
#
echo ""
echo "--- Test 4: Write precedence (deny parent THEN allow child) ---"
WRITE_DIR="$HOME/.seatbelt_write_test_$$"
mkdir -p "$WRITE_DIR/parent/child"
echo "original" >"$WRITE_DIR/parent/child/file.txt"

POLICY=$(mktemp)
cat >"$POLICY" <<EOF
(version 1)
(allow default)
(deny file-write* (subpath "$WRITE_DIR/parent"))
(allow file-write* (subpath "$WRITE_DIR/parent/child"))
EOF

if sandbox-exec -f "$POLICY" sh -c "echo modified > '$WRITE_DIR/parent/child/file.txt'" 2>/dev/null; then
	if [[ "$(cat "$WRITE_DIR/parent/child/file.txt")" == "modified" ]]; then
		pass "Write to child allowed"
	else
		fail "Write command succeeded but file not modified"
	fi
else
	fail "Write to child should be allowed"
fi

# Verify can't write to parent directly
if sandbox-exec -f "$POLICY" sh -c "echo bad > '$WRITE_DIR/parent/newfile.txt'" 2>/dev/null; then
	fail "Write to parent should be denied"
	rm -f "$WRITE_DIR/parent/newfile.txt"
else
	pass "Write to parent correctly denied"
fi

rm -f "$POLICY"
rm -rf "$WRITE_DIR"

#
# Summary
#
echo ""
echo "=== Results ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""
echo "=== Conclusion ==="
echo "Seatbelt uses LAST-MATCH-WINS semantics."
echo "To allow a subpath inside a denied parent, emit rules in this order:"
echo "  1. (deny file-read* (subpath \"/parent\"))"
echo "  2. (allow file-read* (subpath \"/parent/child\"))"

if [[ $FAILED -gt 0 ]]; then
	exit 1
fi
