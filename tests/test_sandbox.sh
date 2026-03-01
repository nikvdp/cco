#!/usr/bin/env bash
# Cross-platform sandbox tests
# Works on both Linux (bwrap) and macOS (Seatbelt)

set -euo pipefail

cd "$(dirname "$0")/.."

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

OS="$(uname -s)"
ARCH="$(uname -m)"

echo "=== Sandbox Tests ==="
echo "Platform: $OS ($ARCH)"
echo ""

# Setup test directory
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

#
# Basic execution tests
#

echo "--- Basic Execution ---"

echo "Test: Basic command execution"
if output=$(./sandbox echo "hello sandbox" 2>&1) && [[ "$output" == "hello sandbox" ]]; then
	pass "Basic command execution"
else
	fail "Basic command execution: got '$output'"
fi

echo "Test: Exit code preserved"
exit_code=0
./sandbox sh -c 'exit 42' || exit_code=$?
if [[ $exit_code -eq 42 ]]; then
	pass "Exit code preserved"
else
	fail "Exit code preserved: expected 42, got $exit_code"
fi

echo "Test: Environment variables inherited"
# shellcheck disable=SC2016  # Intentional: $TEST_VAR should expand in the subshell, not here
if output=$(TEST_VAR="test_value" ./sandbox sh -c 'echo $TEST_VAR' 2>&1) && [[ "$output" == "test_value" ]]; then
	pass "Environment variables inherited"
else
	fail "Environment variables inherited: got '$output'"
fi

#
# Write restriction tests
#

echo ""
echo "--- Write Restrictions ---"

echo "Test: Current directory is writable"
test_file="$PWD/test_write_$$"
if ./sandbox sh -c "echo test > '$test_file'" 2>/dev/null && [[ -f "$test_file" ]]; then
	rm -f "$test_file"
	pass "Current directory is writable"
else
	rm -f "$test_file" 2>/dev/null || true
	fail "Current directory is writable"
fi

echo "Test: /tmp is writable"
if ./sandbox sh -c 'echo test > /tmp/sandbox_test_$$ && rm /tmp/sandbox_test_$$' 2>/dev/null; then
	pass "/tmp is writable"
else
	fail "/tmp is writable"
fi

echo "Test: System directories not writable"
# Try to write to /usr which should be denied
if ./sandbox sh -c 'echo test > /usr/sandbox_test_file' 2>/dev/null; then
	fail "System directories not writable: /usr was writable"
	rm -f /usr/sandbox_test_file 2>/dev/null || true
else
	pass "System directories not writable"
fi

#
# Write path (-w) tests
#

echo ""
echo "--- Write Path Tests ---"

echo "Test: -w flag allows writes to specified directory"
mkdir -p "$TEST_DIR/write_test"
if ./sandbox -w "$TEST_DIR/write_test" sh -c "echo test > '$TEST_DIR/write_test/file'" 2>/dev/null; then
	if [[ -f "$TEST_DIR/write_test/file" ]]; then
		pass "-w flag allows writes to specified directory"
	else
		fail "-w flag allows writes: file not created"
	fi
else
	fail "-w flag allows writes to specified directory"
fi

echo "Test: -w flag allows writes to specified file"
touch "$TEST_DIR/write_file"
if ./sandbox -w "$TEST_DIR/write_file" sh -c "echo test > '$TEST_DIR/write_file'" 2>/dev/null; then
	if [[ "$(cat "$TEST_DIR/write_file")" == "test" ]]; then
		pass "-w flag allows writes to specified file"
	else
		fail "-w flag allows writes to file: content mismatch"
	fi
else
	fail "-w flag allows writes to specified file"
fi

#
# Read-only path tests
#

echo ""
echo "--- Read-Only Path Tests ---"

echo "Test: --read-only allows reads"
mkdir -p "$TEST_DIR/ro_test"
echo "readonly_content" >"$TEST_DIR/ro_test/file"
if output=$(./sandbox --read-only "$TEST_DIR/ro_test" cat "$TEST_DIR/ro_test/file" 2>&1) && [[ "$output" == "readonly_content" ]]; then
	pass "--read-only allows reads"
else
	fail "--read-only allows reads: got '$output'"
fi

echo "Test: --read-only blocks writes"
# Note: On macOS, /var/folders and /tmp are pre-allowed for writes in the Seatbelt policy,
# so we test with a directory under $HOME which is not pre-allowed (outside safe mode)
RO_TEST_DIR="$HOME/.sandbox_ro_test_$$"
mkdir -p "$RO_TEST_DIR"
echo "original" >"$RO_TEST_DIR/file"
if ./sandbox --read-only "$RO_TEST_DIR" sh -c "echo modified > '$RO_TEST_DIR/file'" 2>/dev/null; then
	# Check if file was actually modified (some systems may silently fail)
	if [[ "$(cat "$RO_TEST_DIR/file")" == "original" ]]; then
		rm -rf "$RO_TEST_DIR"
		pass "--read-only blocks writes"
	else
		rm -rf "$RO_TEST_DIR"
		fail "--read-only blocks writes: file was modified"
	fi
else
	rm -rf "$RO_TEST_DIR"
	pass "--read-only blocks writes"
fi

#
# Deny path tests
#

echo ""
echo "--- Deny Path Tests ---"

echo "Test: --deny blocks reads to directory"
mkdir -p "$TEST_DIR/deny_test"
echo "secret" >"$TEST_DIR/deny_test/file"
if ./sandbox --deny "$TEST_DIR/deny_test" cat "$TEST_DIR/deny_test/file" 2>/dev/null; then
	fail "--deny blocks reads: file was readable"
else
	pass "--deny blocks reads to directory"
fi

echo "Test: --deny blocks reads to file"
echo "secret" >"$TEST_DIR/deny_file"
if ./sandbox --deny "$TEST_DIR/deny_file" cat "$TEST_DIR/deny_file" 2>/dev/null; then
	fail "--deny blocks reads to file: file was readable"
else
	pass "--deny blocks reads to file"
fi

echo "Test: --deny blocks listing directory"
mkdir -p "$TEST_DIR/deny_ls"
touch "$TEST_DIR/deny_ls/file1" "$TEST_DIR/deny_ls/file2"
if output=$(./sandbox --deny "$TEST_DIR/deny_ls" ls "$TEST_DIR/deny_ls" 2>/dev/null) && [[ -n "$output" ]]; then
	fail "--deny blocks listing: got '$output'"
else
	pass "--deny blocks listing directory"
fi

#
# Allow-inside-deny tests
#

echo ""
echo "--- Allow-Inside-Deny Tests ---"

# Setup for allow-inside-deny tests
# Use $HOME subdir instead of $TEST_DIR (/var/folders) because /var/folders is globally writable
AID_TEST_DIR="$HOME/.sandbox_aid_test_$$"
mkdir -p "$AID_TEST_DIR/parent/child"
echo "child_content" >"$AID_TEST_DIR/parent/child/file.txt"
echo "sibling_content" >"$AID_TEST_DIR/parent/sibling.txt"

echo "Test: --read-only inside --deny allows reads to child"
if output=$(./sandbox --deny "$AID_TEST_DIR/parent" --read-only "$AID_TEST_DIR/parent/child" cat "$AID_TEST_DIR/parent/child/file.txt" 2>/dev/null) && [[ "$output" == "child_content" ]]; then
	pass "--read-only inside --deny allows reads to child"
else
	fail "--read-only inside --deny: could not read child, got '$output'"
fi

echo "Test: --read-only file inside --deny allows reads to file"
if output=$(./sandbox --deny "$AID_TEST_DIR/parent" --read-only "$AID_TEST_DIR/parent/child/file.txt" cat "$AID_TEST_DIR/parent/child/file.txt" 2>/dev/null) && [[ "$output" == "child_content" ]]; then
	pass "--read-only file inside --deny allows reads to file"
else
	fail "--read-only file inside --deny: could not read file, got '$output'"
fi

echo "Test: --read-only inside --deny still blocks sibling"
if ./sandbox --deny "$AID_TEST_DIR/parent" --read-only "$AID_TEST_DIR/parent/child" cat "$AID_TEST_DIR/parent/sibling.txt" 2>/dev/null; then
	fail "--read-only inside --deny: sibling was readable"
else
	pass "--read-only inside --deny still blocks sibling"
fi

echo "Test: --read-only inside --deny blocks listing parent"
if output=$(./sandbox --deny "$AID_TEST_DIR/parent" --read-only "$AID_TEST_DIR/parent/child" ls "$AID_TEST_DIR/parent" 2>/dev/null) && [[ -n "$output" ]]; then
	fail "--read-only inside --deny: parent was listable: '$output'"
else
	pass "--read-only inside --deny blocks listing parent"
fi

echo "Test: -w inside --deny allows writes to child"
echo "original" >"$AID_TEST_DIR/parent/child/file.txt"
if ./sandbox --deny "$AID_TEST_DIR/parent" -w "$AID_TEST_DIR/parent/child" sh -c "echo modified > '$AID_TEST_DIR/parent/child/file.txt'" 2>/dev/null; then
	if [[ "$(cat "$AID_TEST_DIR/parent/child/file.txt")" == "modified" ]]; then
		pass "-w inside --deny allows writes to child"
	else
		fail "-w inside --deny: write succeeded but content wrong"
	fi
else
	fail "-w inside --deny: could not write to child"
fi

echo "Test: -w inside --deny allows reads to child"
if output=$(./sandbox --deny "$AID_TEST_DIR/parent" -w "$AID_TEST_DIR/parent/child" cat "$AID_TEST_DIR/parent/child/file.txt" 2>/dev/null) && [[ "$output" == "modified" ]]; then
	pass "-w inside --deny allows reads to child"
else
	fail "-w inside --deny: could not read child, got '$output'"
fi

echo "Test: -w inside --deny blocks writes to parent"
if ./sandbox --deny "$AID_TEST_DIR/parent" -w "$AID_TEST_DIR/parent/child" sh -c "echo bad > '$AID_TEST_DIR/parent/badfile.txt'" 2>/dev/null; then
	fail "-w inside --deny: parent was writable"
	rm -f "$AID_TEST_DIR/parent/badfile.txt"
else
	pass "-w inside --deny blocks writes to parent"
fi

# Cleanup allow-inside-deny test dir
rm -rf "$AID_TEST_DIR"

#
# Paths with spaces tests (issue #29)
#

echo ""
echo "--- Paths With Spaces (issue #29) ---"

# Setup dirs with spaces
SPACE_TEST_DIR="$HOME/.sandbox_space_test_$$"
mkdir -p "$SPACE_TEST_DIR/My Games"
mkdir -p "$SPACE_TEST_DIR/System Volume Information"
mkdir -p "$SPACE_TEST_DIR/Read Only Dir"
echo "secret" >"$SPACE_TEST_DIR/System Volume Information/data.txt"
echo "game_content" >"$SPACE_TEST_DIR/My Games/save.txt"
echo "ro_content" >"$SPACE_TEST_DIR/Read Only Dir/file.txt"

echo "Test: --deny with spaces works alongside -w"
if ./sandbox --deny "$SPACE_TEST_DIR/System Volume Information" -w "$SPACE_TEST_DIR/My Games" \
	cat "$SPACE_TEST_DIR/System Volume Information/data.txt" 2>/dev/null; then
	fail "--deny with spaces + -w: denied path was readable"
else
	pass "--deny with spaces works alongside -w"
fi

echo "Test: -w with spaces works alongside --deny"
if output=$(./sandbox --deny "$SPACE_TEST_DIR/System Volume Information" -w "$SPACE_TEST_DIR/My Games" \
	cat "$SPACE_TEST_DIR/My Games/save.txt" 2>&1) && [[ "$output" == "game_content" ]]; then
	pass "-w with spaces works alongside --deny"
else
	fail "-w with spaces + --deny: could not read writable path, got '$output'"
fi

echo "Test: --deny with spaces works alongside --read-only"
if ./sandbox --deny "$SPACE_TEST_DIR/System Volume Information" --read-only "$SPACE_TEST_DIR/Read Only Dir" \
	cat "$SPACE_TEST_DIR/System Volume Information/data.txt" 2>/dev/null; then
	fail "--deny with spaces + --read-only: denied path was readable"
else
	pass "--deny with spaces works alongside --read-only"
fi

echo "Test: --read-only with spaces works alongside --deny"
if output=$(./sandbox --deny "$SPACE_TEST_DIR/System Volume Information" --read-only "$SPACE_TEST_DIR/Read Only Dir" \
	cat "$SPACE_TEST_DIR/Read Only Dir/file.txt" 2>&1) && [[ "$output" == "ro_content" ]]; then
	pass "--read-only with spaces works alongside --deny"
else
	fail "--read-only with spaces + --deny: could not read ro path, got '$output'"
fi

echo "Test: all three flag types with spaces in paths"
if output=$(./sandbox --deny "$SPACE_TEST_DIR/System Volume Information" \
	--read-only "$SPACE_TEST_DIR/Read Only Dir" \
	-w "$SPACE_TEST_DIR/My Games" \
	sh -c "cat '$SPACE_TEST_DIR/Read Only Dir/file.txt' && echo writable > '$SPACE_TEST_DIR/My Games/new.txt' && cat '$SPACE_TEST_DIR/My Games/new.txt'" 2>&1) &&
	[[ "$output" == *"ro_content"* ]] && [[ "$output" == *"writable"* ]]; then
	pass "all three flag types with spaces in paths"
else
	fail "all three flag types with spaces: got '$output'"
fi

echo "Test: --deny still blocks when all three flags have spaces"
if ./sandbox --deny "$SPACE_TEST_DIR/System Volume Information" \
	--read-only "$SPACE_TEST_DIR/Read Only Dir" \
	-w "$SPACE_TEST_DIR/My Games" \
	cat "$SPACE_TEST_DIR/System Volume Information/data.txt" 2>/dev/null; then
	fail "--deny still blocks with all three flags: denied path was readable"
else
	pass "--deny still blocks when all three flags have spaces"
fi

# Cleanup
rm -rf "$SPACE_TEST_DIR"

#
# Safe mode tests
#

echo ""
echo "--- Safe Mode Tests ---"

echo "Test: --safe hides home directory contents"
# Create a test file in home
test_home_file="$HOME/.sandbox_test_$$"
echo "home_content" >"$test_home_file"
if ./sandbox --safe cat "$test_home_file" 2>/dev/null; then
	rm -f "$test_home_file"
	fail "--safe hides home directory: file was readable"
else
	rm -f "$test_home_file"
	pass "--safe hides home directory contents"
fi

echo "Test: --safe still allows current directory access"
if output=$(./sandbox --safe pwd 2>&1) && [[ "$output" == "$PWD" ]]; then
	pass "--safe still allows current directory access"
else
	fail "--safe still allows current directory: got '$output'"
fi

echo "Test: --safe allows lstat on home directory"
if ./sandbox --safe stat "$HOME" >/dev/null 2>&1; then
	pass "--safe allows lstat on home directory"
else
	fail "--safe allows lstat on home directory"
fi

echo "Test: --safe still denies listing home directory contents"
if ./sandbox --safe ls "$HOME" >/dev/null 2>&1; then
	fail "--safe denies listing home: ls succeeded"
else
	pass "--safe denies listing home directory contents"
fi

echo "Test: --safe allows lstat on ancestor dirs between HOME and CWD"
parent="$(dirname "$PWD")"
if [[ "$parent" == "$HOME"/* || "$parent" == "$HOME" ]]; then
	if ./sandbox --safe stat "$parent" >/dev/null 2>&1; then
		pass "--safe allows lstat on ancestor dirs"
	else
		fail "--safe allows lstat on ancestor dirs"
	fi
else
	skip "--safe ancestor test: CWD not under HOME"
fi

echo "Test: --safe denies reading files from ancestor dirs under HOME"
ancestor="$PWD"
read_blocked=true
while [[ "$ancestor" != "$HOME" && "$ancestor" == "$HOME"/* ]]; do
	ancestor="$(dirname "$ancestor")"
	if ./sandbox --safe ls "$ancestor" >/dev/null 2>&1; then
		read_blocked=false
		fail "--safe denies reading ancestors: ls $ancestor succeeded"
		break
	fi
done
if [[ "$read_blocked" == true ]]; then
	if [[ "$(dirname "$PWD")" == "$HOME"/* || "$(dirname "$PWD")" == "$HOME" ]]; then
		pass "--safe denies reading files from ancestor dirs under HOME"
	else
		skip "--safe ancestor read test: CWD not under HOME"
	fi
fi

#
# Platform-specific tests
#

echo ""
echo "--- Platform-Specific Tests ---"

if [[ "$OS" == "Linux" ]]; then
	echo "Test: bwrap is available"
	if command -v bwrap >/dev/null 2>&1; then
		pass "bwrap is available"
	else
		fail "bwrap is available"
	fi
elif [[ "$OS" == "Darwin" ]]; then
	echo "Test: sandbox-exec is available"
	if command -v sandbox-exec >/dev/null 2>&1; then
		pass "sandbox-exec is available"
	else
		fail "sandbox-exec is available"
	fi
fi

#
# Summary
#

echo ""
echo "=== Results ==="
echo "Passed:  $PASSED"
echo "Failed:  $FAILED"
echo "Skipped: $SKIPPED"

if [[ $FAILED -gt 0 ]]; then
	exit 1
fi
