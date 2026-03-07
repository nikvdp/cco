#!/usr/bin/env bash
# Test additionalDirectories loading from .claude/settings.local.json
# Verifies valid dirs are added, missing dirs warn, and missing file is silent.

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

supports_backend() {
	local backend="$1"
	case "$backend" in
	native)
		if [[ "$(uname -s)" == "Darwin" ]]; then
			command -v sandbox-exec >/dev/null 2>&1
		else
			command -v bwrap >/dev/null 2>&1
		fi
		;;
	docker)
		command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
		;;
	*)
		return 1
		;;
	esac
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

run_case() {
	local backend="$1"
	local label="$2"
	local work_dir="$3"
	local home_dir="$4"
	local out_file="$5"
	shift 5

	echo "Test: $label ($backend)"
	if (cd "$work_dir" && HOME="$home_dir" "$CCO_BIN" --backend "$backend" --command true "$@") >"$out_file" 2>&1; then
		pass "$label runs successfully ($backend)"
	else
		echo "  output:"
		sed 's/^/    /' "$out_file"
		fail "$label runs successfully ($backend)"
	fi
}

echo "=== Additional Directories from Settings Tests ==="
echo "Platform: $(uname -s) ($(uname -m))"
echo ""

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME"

# Project dir with .claude/settings.local.json
PROJ_DIR="$TEST_ROOT/project"
mkdir -p "$PROJ_DIR/.claude"

# Extra directories to be referenced from settings
EXTRA_DIR_A="$TEST_ROOT/extra-a"
EXTRA_DIR_B="$TEST_ROOT/extra-b"
mkdir -p "$EXTRA_DIR_A" "$EXTRA_DIR_B"

# Initialize a git repo so cco doesn't complain
git init "$PROJ_DIR" >/dev/null
git -C "$PROJ_DIR" config user.email "test@example.com"
git -C "$PROJ_DIR" config user.name "tester"

for backend in native docker; do
	if ! supports_backend "$backend"; then
		skip "backend unavailable: $backend"
		continue
	fi

	# Test 1: Valid directories are picked up
	cat >"$PROJ_DIR/.claude/settings.local.json" <<EOF
{"additionalDirectories": ["$EXTRA_DIR_A", "$EXTRA_DIR_B"]}
EOF
	run_case "$backend" "valid additional directories" "$PROJ_DIR" "$TEST_HOME" "$TEST_ROOT/valid_${backend}.log"
	assert_contains "$TEST_ROOT/valid_${backend}.log" \
		"Adding additional directory from settings: $EXTRA_DIR_A" \
		"settings adds first directory ($backend)"
	assert_contains "$TEST_ROOT/valid_${backend}.log" \
		"Adding additional directory from settings: $EXTRA_DIR_B" \
		"settings adds second directory ($backend)"

	# Test 2: Non-existent directory produces a warning
	cat >"$PROJ_DIR/.claude/settings.local.json" <<EOF
{"additionalDirectories": ["/tmp/no-such-dir-$RANDOM$RANDOM"]}
EOF
	run_case "$backend" "non-existent directory" "$PROJ_DIR" "$TEST_HOME" "$TEST_ROOT/nodir_${backend}.log"
	assert_contains "$TEST_ROOT/nodir_${backend}.log" \
		"Skipping additionalDirectories entry (not a directory)" \
		"non-existent directory warns ($backend)"

	# Test 3: No settings file — silent, no error
	rm -f "$PROJ_DIR/.claude/settings.local.json"
	run_case "$backend" "no settings file" "$PROJ_DIR" "$TEST_HOME" "$TEST_ROOT/nosettings_${backend}.log"
	assert_not_contains "$TEST_ROOT/nosettings_${backend}.log" \
		"additionalDirectories" \
		"no settings file produces no additionalDirectories output ($backend)"

	# Test 4: Empty additionalDirectories array — silent
	cat >"$PROJ_DIR/.claude/settings.local.json" <<EOF
{"additionalDirectories": []}
EOF
	run_case "$backend" "empty additional directories" "$PROJ_DIR" "$TEST_HOME" "$TEST_ROOT/empty_${backend}.log"
	assert_not_contains "$TEST_ROOT/empty_${backend}.log" \
		"Adding additional directory from settings" \
		"empty array adds no directories ($backend)"
done

echo ""
echo "=== Results ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Skipped: $SKIPPED"

if [[ $FAILED -gt 0 ]]; then
	exit 1
fi
