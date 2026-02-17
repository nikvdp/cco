#!/usr/bin/env bash
# Regression tests for Codex mode behavior in Docker backend.
# Focus: help/version passthrough, Docker codex-mode defaults, and
# compatibility with --allow-readonly ~/.claude + --add-dir ~/.codex.

set -euo pipefail

cd "$(dirname "$0")/.."

CCO_BIN="$PWD/cco"

PASSED=0
FAILED=0
SKIPPED=0

pass() {
	echo "PASS: $1"
	PASSED=$((PASSED + 1))
}

fail() {
	echo "FAIL: $1"
	FAILED=$((FAILED + 1))
}

skip() {
	echo "SKIP: $1"
	SKIPPED=$((SKIPPED + 1))
}

assert_contains() {
	local file="$1"
	local expected="$2"
	local name="$3"
	if grep -Fq -- "$expected" "$file"; then
		pass "$name"
	else
		echo "  expected to find: $expected"
		echo "  output:"
		sed 's/^/    /' "$file"
		fail "$name"
	fi
}

assert_not_contains() {
	local file="$1"
	local unexpected="$2"
	local name="$3"
	if grep -Fq -- "$unexpected" "$file"; then
		echo "  unexpected content found: $unexpected"
		echo "  output:"
		sed 's/^/    /' "$file"
		fail "$name"
	else
		pass "$name"
	fi
}

supports_docker() {
	command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

echo "=== Codex Docker Mode Regression Tests ==="
echo "Platform: $(uname -s) ($(uname -m))"
echo ""

if ! supports_docker; then
	skip "docker backend unavailable"
	echo ""
	echo "=== Results ==="
	echo "Passed: $PASSED"
	echo "Failed: $FAILED"
	echo "Skipped: $SKIPPED"
	exit 0
fi

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

echo "Test: cco codex --help works in Docker backend"
if "$CCO_BIN" --backend docker codex --help >"$TEST_ROOT/help.log" 2>&1; then
	pass "cco codex --help exited successfully"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/help.log"
	fail "cco codex --help exited successfully"
fi
assert_contains "$TEST_ROOT/help.log" "Codex CLI" "codex help output is shown"
assert_contains "$TEST_ROOT/help.log" \
	"Codex help/version requested; skipping Docker sandbox fallback injection" \
	"help/version passthrough skips sandbox fallback injection"
assert_contains "$TEST_ROOT/help.log" \
	"Added Codex Docker default argument '--no-alt-screen'" \
	"docker codex default no-alt-screen flag is applied"
assert_contains "$TEST_ROOT/help.log" \
	"Setting CODEX_HOME in container: /home/hostuser/.codex" \
	"CODEX_HOME is exported in docker codex-mode"
assert_not_contains "$TEST_ROOT/help.log" \
	"cannot execute: required file not found" \
	"codex shim does not recurse into itself"

echo ""
echo "Test: codex-mode with allow-readonly + add-dir succeeds"
if "$CCO_BIN" --backend docker --allow-readonly "$HOME/.claude" --add-dir "$HOME/.codex" --codex-mode codex --help >"$TEST_ROOT/readonly_codex_mode.log" 2>&1; then
	pass "codex-mode command with allow-readonly/add-dir exited successfully"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/readonly_codex_mode.log"
	fail "codex-mode command with allow-readonly/add-dir exited successfully"
fi
assert_contains "$TEST_ROOT/readonly_codex_mode.log" "Codex CLI" \
	"codex help still works with allow-readonly/add-dir"
assert_contains "$TEST_ROOT/readonly_codex_mode.log" \
	"Mounting read-only path: $HOME/.claude" \
	"requested read-only claude path is mounted"
assert_not_contains "$TEST_ROOT/readonly_codex_mode.log" \
	"Duplicate mount point" \
	"no duplicate docker mount point error"

echo ""
echo "=== Results ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Skipped: $SKIPPED"

if [[ $FAILED -gt 0 ]]; then
	exit 1
fi
