#!/usr/bin/env bash
# Test additionalDirectories loading from .claude/settings.local.json.
# Verifies configured directories are actually usable inside the sandbox.

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

run_command_case() {
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

run_shell_case() {
	local backend="$1"
	local label="$2"
	local work_dir="$3"
	local home_dir="$4"
	local out_file="$5"
	local shell_command="$6"

	echo "Test: $label ($backend)"
	if (cd "$work_dir" && HOME="$home_dir" "$CCO_BIN" --backend "$backend" shell "$shell_command") >"$out_file" 2>&1; then
		pass "$label runs successfully ($backend)"
	else
		echo "  output:"
		sed 's/^/    /' "$out_file"
		fail "$label runs successfully ($backend)"
	fi
}

assert_file_content() {
	local file="$1"
	local expected="$2"
	local name="$3"
	local actual=""
	if [[ -f "$file" ]]; then
		actual=$(cat "$file")
	fi
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		echo "  expected file $file to contain: $expected"
		if [[ -f "$file" ]]; then
			echo "  actual content: $actual"
		else
			echo "  file is missing"
		fi
		fail "$name"
	fi
}

build_tool_bin() {
	local dest="$1"
	shift
	mkdir -p "$dest"
	local tool src
	for tool in "$@"; do
		src=$(command -v "$tool" 2>/dev/null || true)
		if [[ -n "$src" ]]; then
			ln -sf "$src" "$dest/$tool"
		fi
	done
}

run_loader_case() {
	local label="$1"
	local work_dir="$2"
	local home_dir="$3"
	local path_override="$4"
	local out_file="$5"
	local body="$6"
	local loader_script="$TEST_ROOT/loader_case.sh"

	cat >"$loader_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

warn() { echo "WARN: $*"; }
log() { :; }

# shellcheck disable=SC1090,SC2046
eval "$(sed -n '
  /^path_in_array()/,/^}/p
  /^remove_path_from_array()/,/^}/p
  /^resolve_path()/,/^}/p
  /^add_rw_path()/,/^}/p
  /^load_additional_directories_from_settings()/,/^}/p
' "$CCO_BIN")"

additional_dirs=()
additional_ro_paths=()
deny_paths=()
EOF
	printf 'cd %q\n' "$work_dir" >>"$loader_script"
	printf 'HOME=%q\n' "$home_dir" >>"$loader_script"
	printf '%s\n' "$body" >>"$loader_script"

	echo "Test: $label"
	if PATH="$path_override" CCO_BIN="$CCO_BIN" /bin/bash "$loader_script" >"$out_file" 2>&1; then
		pass "$label runs successfully"
	else
		echo "  output:"
		sed 's/^/    /' "$out_file"
		fail "$label runs successfully"
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
EXTRA_DIR_B="$TEST_HOME/extra-b"
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

	# Test 1: Valid directories are usable inside the sandbox
	printf 'host-a' >"$EXTRA_DIR_A/from_host.txt"
	printf 'host-b' >"$EXTRA_DIR_B/from_host.txt"
	rm -f "$EXTRA_DIR_A/from_sandbox.txt" "$EXTRA_DIR_B/from_sandbox.txt"
	cat >"$PROJ_DIR/.claude/settings.local.json" <<EOF
{"additionalDirectories": ["$EXTRA_DIR_A", "$EXTRA_DIR_B"]}
EOF
	run_shell_case "$backend" "valid additional directories" "$PROJ_DIR" "$TEST_HOME" "$TEST_ROOT/valid_${backend}.log" \
		"cat \"$EXTRA_DIR_A/from_host.txt\" >/dev/null && cat \"$EXTRA_DIR_B/from_host.txt\" >/dev/null && printf \"$backend-a\" > \"$EXTRA_DIR_A/from_sandbox.txt\" && printf \"$backend-b\" > \"$EXTRA_DIR_B/from_sandbox.txt\""
	assert_file_content "$EXTRA_DIR_A/from_sandbox.txt" "$backend-a" \
		"settings allows write access to external dir ($backend)"
	assert_file_content "$EXTRA_DIR_B/from_sandbox.txt" "$backend-b" \
		"settings allows write access to home dir ($backend)"

	# Test 2: Non-existent directory produces a warning
	cat >"$PROJ_DIR/.claude/settings.local.json" <<EOF
{"additionalDirectories": ["/tmp/no-such-dir-$RANDOM$RANDOM"]}
EOF
	run_command_case "$backend" "non-existent directory" "$PROJ_DIR" "$TEST_HOME" "$TEST_ROOT/nodir_${backend}.log"
	assert_contains "$TEST_ROOT/nodir_${backend}.log" \
		"Skipping additionalDirectories entry (not a directory)" \
		"non-existent directory warns ($backend)"

	# Test 3: No settings file — silent, no error
	rm -f "$PROJ_DIR/.claude/settings.local.json"
	run_command_case "$backend" "no settings file" "$PROJ_DIR" "$TEST_HOME" "$TEST_ROOT/nosettings_${backend}.log"
	assert_not_contains "$TEST_ROOT/nosettings_${backend}.log" \
		"additionalDirectories" \
		"no settings file produces no additionalDirectories output ($backend)"

	# Test 4: Empty additionalDirectories array — silent
	cat >"$PROJ_DIR/.claude/settings.local.json" <<EOF
{"additionalDirectories": []}
EOF
	run_command_case "$backend" "empty additional directories" "$PROJ_DIR" "$TEST_HOME" "$TEST_ROOT/empty_${backend}.log"
	assert_not_contains "$TEST_ROOT/empty_${backend}.log" \
		"Adding additional directory from settings" \
		"empty array adds no directories ($backend)"

	# Test 5: Invalid JSON warns instead of failing silently
	cat >"$PROJ_DIR/.claude/settings.local.json" <<EOF
{"additionalDirectories":
EOF
	run_command_case "$backend" "invalid settings json" "$PROJ_DIR" "$TEST_HOME" "$TEST_ROOT/invalid_${backend}.log"
	assert_contains "$TEST_ROOT/invalid_${backend}.log" \
		"Skipping additionalDirectories from" \
		"invalid settings file warns ($backend)"

	# Test 6: Wrong-shaped additionalDirectories warns clearly
	cat >"$PROJ_DIR/.claude/settings.local.json" <<EOF
{"additionalDirectories": {"dir": "$EXTRA_DIR_A"}}
EOF
	run_command_case "$backend" "wrong-shaped additional directories" "$PROJ_DIR" "$TEST_HOME" "$TEST_ROOT/wrongshape_${backend}.log"
	assert_contains "$TEST_ROOT/wrongshape_${backend}.log" \
		"additionalDirectories must be an array" \
		"wrong-shaped additionalDirectories warns ($backend)"
done

echo ""
echo "--- Parser Selection ---"

if command -v jq >/dev/null 2>&1; then
	JQ_ONLY_BIN="$TEST_ROOT/jq-only-bin"
	build_tool_bin "$JQ_ONLY_BIN" jq dirname basename sed tr

	cat >"$PROJ_DIR/.claude/settings.local.json" <<EOF
{"additionalDirectories": ["$EXTRA_DIR_A"]}
EOF
	run_loader_case "jq fallback without python3" "$PROJ_DIR" "$TEST_HOME" "$JQ_ONLY_BIN" "$TEST_ROOT/jq_fallback.log" \
		'load_additional_directories_from_settings; printf "ADDED:%s\n" "${additional_dirs[0]:-}"'
	assert_contains "$TEST_ROOT/jq_fallback.log" \
		"ADDED:$EXTRA_DIR_A" \
		"jq fallback adds configured directory"
else
	skip "jq unavailable: skipping jq fallback parser test"
fi

NO_PARSER_BIN="$TEST_ROOT/no-parser-bin"
build_tool_bin "$NO_PARSER_BIN" sed

cat >"$PROJ_DIR/.claude/settings.local.json" <<EOF
{"additionalDirectories": ["$EXTRA_DIR_A"]}
EOF
run_loader_case "missing python3 and jq warns" "$PROJ_DIR" "$TEST_HOME" "$NO_PARSER_BIN" "$TEST_ROOT/no_parser.log" \
	'load_additional_directories_from_settings'
assert_contains "$TEST_ROOT/no_parser.log" \
	"python3/jq not found" \
	"missing parsers warning is surfaced"

echo ""
echo "=== Results ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Skipped: $SKIPPED"

if [[ $FAILED -gt 0 ]]; then
	exit 1
fi
