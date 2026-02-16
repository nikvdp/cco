#!/usr/bin/env bash
# Test git worktree common-dir handling in cco
# Verifies trusted layout, untrusted layout rejection, and explicit override.

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
	if rg -Fq -- "$expected" "$file"; then
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
	if rg -Fq -- "$unexpected" "$file"; then
		echo "  unexpected content found: $unexpected"
		echo "  output:"
		sed 's/^/    /' "$file"
		fail "$name"
	else
		pass "$name"
	fi
}

run_backend_case() {
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

echo "=== Git Worktree Support Tests ==="
echo "Platform: $(uname -s) ($(uname -m))"
echo ""

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME"

MAIN_REPO="$TEST_ROOT/main"
WORKTREE_DIR="$TEST_ROOT/wt"
OTHER_REPO="$TEST_ROOT/other"

git init "$MAIN_REPO" >/dev/null
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "tester"
echo "hello" >"$MAIN_REPO/readme.txt"
git -C "$MAIN_REPO" add readme.txt
git -C "$MAIN_REPO" commit -m "init" >/dev/null
git -C "$MAIN_REPO" worktree add "$WORKTREE_DIR" >/dev/null

git init "$OTHER_REPO" >/dev/null

WORKTREE_ADMIN_DIR=$(sed 's/^gitdir: //' "$WORKTREE_DIR/.git")
COMMONDIR_FILE="$WORKTREE_ADMIN_DIR/commondir"
MAIN_GIT_DIR="$(cd "$MAIN_REPO/.git" && pwd -P)"
OTHER_GIT_DIR="$(cd "$OTHER_REPO/.git" && pwd -P)"

for backend in native docker; do
	if ! supports_backend "$backend"; then
		skip "backend unavailable: $backend"
		continue
	fi

	echo "$MAIN_GIT_DIR" >"$COMMONDIR_FILE"
	run_backend_case "$backend" "trusted worktree" "$WORKTREE_DIR" "$TEST_HOME" "$TEST_ROOT/trusted_${backend}.log"
	assert_contains "$TEST_ROOT/trusted_${backend}.log" \
		"Adding git common dir for worktree support: $MAIN_GIT_DIR" \
		"trusted layout adds git common dir ($backend)"
	assert_not_contains "$TEST_ROOT/trusted_${backend}.log" \
		"Skipping untrusted git common dir layout" \
		"trusted layout does not warn as untrusted ($backend)"
	if [[ "$backend" == "docker" ]]; then
		assert_contains "$TEST_ROOT/trusted_${backend}.log" \
			"Mounting additional directory: $MAIN_GIT_DIR" \
			"docker mounts trusted git common dir without remap"
	fi

	run_backend_case "$backend" "trusted worktree with auto-detect disabled" "$WORKTREE_DIR" "$TEST_HOME" "$TEST_ROOT/disabled_${backend}.log" \
		--disable-git-worktree-common-dir
	assert_contains "$TEST_ROOT/disabled_${backend}.log" \
		"Git worktree common-dir auto-detection disabled by flag" \
		"disable flag logs that auto-detection is disabled ($backend)"
	assert_not_contains "$TEST_ROOT/disabled_${backend}.log" \
		"Adding git common dir for worktree support: $MAIN_GIT_DIR" \
		"disable flag prevents auto-added git common dir ($backend)"

	echo "$OTHER_GIT_DIR" >"$COMMONDIR_FILE"
	run_backend_case "$backend" "untrusted worktree (default)" "$WORKTREE_DIR" "$TEST_HOME" "$TEST_ROOT/untrusted_${backend}.log"
	assert_contains "$TEST_ROOT/untrusted_${backend}.log" \
		"Skipping untrusted git common dir layout: $OTHER_GIT_DIR" \
		"untrusted layout is rejected by default ($backend)"
	assert_not_contains "$TEST_ROOT/untrusted_${backend}.log" \
		"Adding git common dir for worktree support: $OTHER_GIT_DIR" \
		"untrusted layout is not auto-added ($backend)"

	run_backend_case "$backend" "untrusted worktree with override" "$WORKTREE_DIR" "$TEST_HOME" "$TEST_ROOT/override_${backend}.log" \
		--allow-external-git-dir
	assert_contains "$TEST_ROOT/override_${backend}.log" \
		"Adding git common dir for worktree support: $OTHER_GIT_DIR" \
		"override allows external git common dir ($backend)"
	if [[ "$backend" == "docker" ]]; then
		assert_contains "$TEST_ROOT/override_${backend}.log" \
			"Mounting additional directory: $OTHER_GIT_DIR" \
			"docker mounts override git common dir path"
	fi
done

echo ""
echo "=== Results ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Skipped: $SKIPPED"

if [[ $FAILED -gt 0 ]]; then
	exit 1
fi
