#!/usr/bin/env bash
# Tests for ~/.claude.json.lock and ~/.npm writability in native sandbox (issue #23)
# Verifies that Claude Code's atomic-write lock directory and npm cache
# are writable inside the sandbox.

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

echo "=== Claude JSON Lock & npm Writability Tests ==="
echo "Platform: $(uname -s) ($(uname -m))"
echo ""

#
# ~/.claude.json.lock tests
#

echo "--- ~/.claude.json.lock ---"

echo "Test: .claude.json.lock is writable inside sandbox"
if output=$(./cco shell 'touch ~/.claude.json.lock/test_write && rm ~/.claude.json.lock/test_write && echo OK') && [[ "$output" == "OK" ]]; then
	pass ".claude.json.lock is writable inside sandbox"
else
	fail ".claude.json.lock is writable inside sandbox: got '$output'"
fi

echo "Test: Can create and remove files in .claude.json.lock (simulates steno lock)"
if output=$(./cco shell 'mkdir -p ~/.claude.json.lock/subdir && echo data > ~/.claude.json.lock/subdir/lockfile && cat ~/.claude.json.lock/subdir/lockfile && rm -rf ~/.claude.json.lock/subdir') && [[ "$output" == "data" ]]; then
	pass "Can create and remove files in .claude.json.lock"
else
	fail "Can create and remove files in .claude.json.lock: got '$output'"
fi

#
# ~/.claude.json tests
#

echo ""
echo "--- ~/.claude.json ---"

echo "Test: .claude.json is writable inside sandbox"
# Test direct write to the file (not sibling creation, which requires writable $HOME)
if output=$(./cco shell 'cat ~/.claude.json > /tmp/cco_test_backup && cp /tmp/cco_test_backup ~/.claude.json && rm /tmp/cco_test_backup && echo OK') && [[ "$output" == "OK" ]]; then
	pass ".claude.json is writable inside sandbox"
else
	fail ".claude.json is writable inside sandbox"
fi

#
# ~/.npm tests
#

echo ""
echo "--- ~/.npm ---"

echo "Test: .npm is writable inside sandbox"
if output=$(./cco shell 'touch ~/.npm/test_write && rm ~/.npm/test_write && echo OK') && [[ "$output" == "OK" ]]; then
	pass ".npm is writable inside sandbox"
else
	fail ".npm is writable inside sandbox: got '$output'"
fi

echo "Test: Can create subdirectories in .npm (simulates npm cache writes)"
if output=$(./cco shell 'mkdir -p ~/.npm/_cacache/tmp/test_$$ && rmdir ~/.npm/_cacache/tmp/test_$$ && echo OK') && [[ "$output" == "OK" ]]; then
	pass "Can create subdirectories in .npm"
else
	fail "Can create subdirectories in .npm: got '$output'"
fi

#
# ~/.claude directory tests (pre-existing, should still work)
#

echo ""
echo "--- .claude dir (sanity check) ---"

echo "Test: .claude dir is writable inside sandbox"
if output=$(./cco shell 'touch ~/.claude/test_write && rm ~/.claude/test_write && echo OK') && [[ "$output" == "OK" ]]; then
	pass ".claude dir is writable inside sandbox"
else
	fail ".claude dir is writable inside sandbox: got '$output'"
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
