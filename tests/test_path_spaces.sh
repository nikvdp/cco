#!/usr/bin/env bash
# Tests for paths with spaces in --add-dir / --deny-path / --allow-readonly
# Regression test for https://github.com/nikvdp/cco/issues/29
#
# These test the pure bash array logic (no sandbox needed).

set -euo pipefail

cd "$(dirname "$0")/.."

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

echo "=== Path Spaces Tests (issue #29) ==="
echo ""

# Setup: temp dirs with spaces in the names
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/System Volume Information"
mkdir -p "$TEST_DIR/My Games"
mkdir -p "$TEST_DIR/Read Only Dir"

# Source the functions we need from cco.
# We extract them rather than sourcing the whole file to avoid side effects.
# shellcheck disable=SC1090
source <(sed -n '
  /^path_in_array()/,/^}/p
  /^remove_from_array()/,/^}/p
  /^add_rw_path()/,/^}/p
  /^add_ro_path()/,/^}/p
  /^add_deny_path()/,/^}/p
' cco)

# Source the warn helper too
warn() { :; }

#
# Test 1: deny path with spaces survives adding an rw path
#

echo "--- Deny + Add-dir interaction ---"

additional_dirs=()
additional_ro_paths=()
deny_paths=()

add_deny_path "$TEST_DIR/System Volume Information"
add_rw_path "$TEST_DIR/My Games"

echo "Test: deny path with spaces survives adding rw path"
if [[ ${#deny_paths[@]} -eq 1 && "${deny_paths[0]}" == "$TEST_DIR/System Volume Information" ]]; then
	pass "deny path with spaces survives adding rw path"
else
	fail "deny path with spaces got mangled: [${deny_paths[*]}] (${#deny_paths[@]} elements)"
fi

#
# Test 2: rw path with spaces survives adding a deny path
#

additional_dirs=()
additional_ro_paths=()
deny_paths=()

add_rw_path "$TEST_DIR/My Games"
add_deny_path "$TEST_DIR/System Volume Information"

echo "Test: rw path with spaces survives adding deny path"
if [[ ${#additional_dirs[@]} -eq 1 && "${additional_dirs[0]}" == "$TEST_DIR/My Games" ]]; then
	pass "rw path with spaces survives adding deny path"
else
	fail "rw path with spaces got mangled: [${additional_dirs[*]}] (${#additional_dirs[@]} elements)"
fi

#
# Test 3: ro path with spaces survives adding an rw path
#

echo ""
echo "--- Read-only + Add-dir interaction ---"

additional_dirs=()
additional_ro_paths=()
deny_paths=()

add_ro_path "$TEST_DIR/Read Only Dir"
add_rw_path "$TEST_DIR/My Games"

echo "Test: ro path with spaces survives adding rw path"
if [[ ${#additional_ro_paths[@]} -eq 1 && "${additional_ro_paths[0]}" == "$TEST_DIR/Read Only Dir" ]]; then
	pass "ro path with spaces survives adding rw path"
else
	fail "ro path with spaces got mangled: [${additional_ro_paths[*]}] (${#additional_ro_paths[@]} elements)"
fi

#
# Test 4: all three arrays with spaces simultaneously
#

echo ""
echo "--- All three path types with spaces ---"

additional_dirs=()
additional_ro_paths=()
deny_paths=()

add_deny_path "$TEST_DIR/System Volume Information"
add_ro_path "$TEST_DIR/Read Only Dir"
add_rw_path "$TEST_DIR/My Games"

echo "Test: deny path intact after adding all three types"
if [[ ${#deny_paths[@]} -eq 1 && "${deny_paths[0]}" == "$TEST_DIR/System Volume Information" ]]; then
	pass "deny path intact after adding all three types"
else
	fail "deny path mangled: [${deny_paths[*]}] (${#deny_paths[@]} elements)"
fi

echo "Test: ro path intact after adding all three types"
if [[ ${#additional_ro_paths[@]} -eq 1 && "${additional_ro_paths[0]}" == "$TEST_DIR/Read Only Dir" ]]; then
	pass "ro path intact after adding all three types"
else
	fail "ro path mangled: [${additional_ro_paths[*]}] (${#additional_ro_paths[@]} elements)"
fi

echo "Test: rw path intact after adding all three types"
if [[ ${#additional_dirs[@]} -eq 1 && "${additional_dirs[0]}" == "$TEST_DIR/My Games" ]]; then
	pass "rw path intact after adding all three types"
else
	fail "rw path mangled: [${additional_dirs[*]}] (${#additional_dirs[@]} elements)"
fi

#
# Test 5: mutual exclusion still works (promoting a path removes it from old array)
#

echo ""
echo "--- Mutual exclusion with spaces ---"

additional_dirs=()
additional_ro_paths=()
deny_paths=()

add_deny_path "$TEST_DIR/System Volume Information"
echo "Test: promoting denied path to rw removes it from deny_paths"
add_rw_path "$TEST_DIR/System Volume Information"

if [[ ${#deny_paths[@]} -eq 0 ]]; then
	pass "promoting denied path to rw removes it from deny_paths"
else
	fail "deny_paths should be empty after promotion: [${deny_paths[*]}]"
fi

if [[ ${#additional_dirs[@]} -eq 1 && "${additional_dirs[0]}" == "$TEST_DIR/System Volume Information" ]]; then
	pass "promoted path is in additional_dirs with spaces intact"
else
	fail "promoted path mangled in additional_dirs: [${additional_dirs[*]}]"
fi

#
# Summary
#

echo ""
echo "=== Results ==="
echo "Passed:  $PASSED"
echo "Failed:  $FAILED"

if [[ $FAILED -gt 0 ]]; then
	exit 1
fi
