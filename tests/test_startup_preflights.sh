#!/usr/bin/env bash
# Regression tests for startup recovery preflights.
# Covers OAuth refresh prompting, macOS-over-SSH keychain recovery,
# and the global --yes flag.
# shellcheck disable=SC1090,SC2016,SC2030,SC2031,SC2034,SC2317

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
	local haystack="$1"
	local needle="$2"
	local name="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		echo "  expected to find: $needle"
		echo "  output:"
		printf '%s\n' "$haystack" | sed 's/^/    /'
		fail "$name"
	fi
}

supports_docker() {
	command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

echo "=== Startup Preflight Regression Tests ==="
echo "Platform: $(uname -s) ($(uname -m))"
echo ""

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

FUNCTIONS_ONLY="$TEST_ROOT/cco_functions.sh"
sed '/^# Initialize variables$/q' "$CCO_BIN" >"$FUNCTIONS_ONLY"

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "login-keychain" ]]; then
	printf '"/tmp/test-login.keychain-db"\n'
	exit 0
fi
echo "unexpected security invocation: $*" >&2
exit 1
EOF
chmod +x "$FAKE_BIN/security"

echo "Test: --help documents --yes"
if output=$("$CCO_BIN" --help 2>&1); then
	assert_contains "$output" "--yes, -y             Auto-accept startup recovery prompts" "--help shows --yes flag"
	assert_contains "$output" "CLAUDE_CODE_OAUTH_TOKEN" "--help documents external Claude token"
	assert_contains "$output" "ANTHROPIC_AUTH_TOKEN" "--help documents Anthropic auth token passthrough"
	assert_contains "$output" "omp [args...]       Run Oh My Pi in sandbox" "--help shows omp command"
else
	echo "  output:"
	printf '%s\n' "$output" | sed 's/^/    /'
	fail "--help exits successfully"
fi

echo ""
echo "Test: Claude auth helpers follow the current ~/.claude defaults"
if (
	source "$FUNCTIONS_ONLY"
	export HOME="$TEST_ROOT/helper-home"
	export XDG_CONFIG_HOME="$TEST_ROOT/helper-xdg"
	unset CLAUDE_CONFIG_DIR
	[[ "$(get_claude_config_dir)" == "$HOME/.claude" ]]
	[[ "$(find_claude_config_dir)" == "$HOME/.claude" ]]
	CLAUDE_CONFIG_DIR="$TEST_ROOT/custom-claude"
	expected_hash="$(sha256_prefix8 "$CLAUDE_CONFIG_DIR")"
	[[ -n "$expected_hash" ]]
	[[ "$(get_claude_keychain_service_name)" == "Claude Code-credentials-$expected_hash" ]]
); then
	pass "Claude auth helpers prefer ~/.claude and hash custom config dirs"
else
	fail "Claude auth helpers prefer ~/.claude and hash custom config dirs"
fi

echo ""
echo "Test: bjq reads simple paths and array indexes"
if (
	source "$FUNCTIONS_ONLY"
	json_file="$TEST_ROOT/bjq.json"
	printf '%s\n' '{"permissions":{"defaultMode":"auto"},"items":[{"name":"first"},{"name":"second"}],"count":42,"enabled":false,"empty":null,"object":{"x":1},"array":["x","y"]}' >"$json_file"
	[[ "$(bjq "permissions.defaultMode" "$json_file")" == "auto" ]]
	[[ "$(bjq ".items[1].name" "$json_file")" == "second" ]]
	[[ "$(bjq "count" "$json_file")" == "42" ]]
	[[ "$(bjq "enabled" "$json_file")" == "false" ]]
	[[ "$(bjq "empty" "$json_file")" == "null" ]]
	[[ "$(bjq "object" "$json_file")" == '{"x":1}' ]]
	[[ "$(bjq "array" "$json_file")" == '["x","y"]' ]]
	[[ "$(bjq_type "items" "$json_file")" == "array" ]]
	[[ "$(printf '{"stdin":["a","b"]}' | bjq "stdin[1]")" == "b" ]]
	! bjq "missing.key" "$json_file" >/dev/null 2>&1
	! bjq "items[-1]" "$json_file" >/dev/null 2>&1
	! bjq "items..name" "$json_file" >/dev/null 2>&1
	bad_json_file="$TEST_ROOT/bjq-bad.json"
	printf '{"broken":\n' >"$bad_json_file"
	if bjq "broken" "$bad_json_file" >/dev/null 2>&1; then
		false
	else
		[[ $? -eq 2 ]]
	fi
); then
	pass "bjq reads simple paths and array indexes"
else
	fail "bjq reads simple paths and array indexes"
fi

echo ""
echo "Test: bjq falls back to python3 when jq is absent"
python_path=$(command -v python3 2>/dev/null || true)
if [[ -z "$python_path" ]]; then
	skip "python3 unavailable for bjq fallback"
elif (
	source "$FUNCTIONS_ONLY"
	fallback_bin="$TEST_ROOT/bjq-python-bin"
	mkdir -p "$fallback_bin"
	ln -s "$python_path" "$fallback_bin/python3"
	ln -s "$(command -v mktemp)" "$fallback_bin/mktemp"
	ln -s "$(command -v cat)" "$fallback_bin/cat"
	ln -s "$(command -v rm)" "$fallback_bin/rm"
	json_file="$TEST_ROOT/bjq-python.json"
	printf '%s\n' '{"items":[{"name":"first"},{"name":"second"}]}' >"$json_file"
	PATH="$fallback_bin"
	[[ "$(bjq "items[1].name" "$json_file")" == "second" ]]
	[[ "$(bjq_type "items[0]" "$json_file")" == "object" ]]
	bad_json_file="$TEST_ROOT/bjq-python-bad.json"
	printf '{"broken":\n' >"$bad_json_file"
	if bjq "broken" "$bad_json_file" >/dev/null 2>&1; then
		false
	else
		[[ $? -eq 2 ]]
	fi
); then
	pass "bjq falls back to python3 when jq is absent"
else
	fail "bjq falls back to python3 when jq is absent"
fi

echo ""
echo "Test: login keychain paths are trimmed before reuse"
if (
	source "$FUNCTIONS_ONLY"
	security() {
		if [[ "${1:-}" == "login-keychain" ]]; then
			printf '    \"/tmp/test-login.keychain-db\"  \n'
			return 0
		fi
		echo "unexpected security invocation: $*" >&2
		return 1
	}
	[[ "$(get_login_keychain_path)" == "/tmp/test-login.keychain-db" ]]
); then
	pass "login keychain paths are trimmed"
else
	fail "login keychain paths are trimmed"
fi

echo ""
echo "Test: non-Claude modes skip Claude authentication preflight"
if (
	source "$FUNCTIONS_ONLY"
	command_flag=""
	CCO_COMMAND=""
	shell_mode=false
	needs_claude_authentication

	shell_mode=true
	! needs_claude_authentication
	shell_mode=false

	command_flag="codex"
	! needs_claude_authentication
	command_flag="opencode"
	! needs_claude_authentication
	command_flag=""

	CCO_COMMAND="custom-tool"
	! needs_claude_authentication
	unset CCO_COMMAND
); then
	pass "non-Claude modes skip Claude authentication preflight"
else
	fail "non-Claude modes skip Claude authentication preflight"
fi

echo ""
echo "Test: OMP mode registers its command and writable state roots"
if (
	source "$FUNCTIONS_ONLY"
	export HOME="$TEST_ROOT/omp-home"
	export PI_CODING_AGENT_DIR="$TEST_ROOT/omp-agent"
	export XDG_DATA_HOME="$TEST_ROOT/xdg-data"
	export XDG_STATE_HOME="$TEST_ROOT/xdg-state"
	export XDG_CACHE_HOME="$TEST_ROOT/xdg-cache"
	mkdir -p \
		"$HOME/.omp" \
		"$PI_CODING_AGENT_DIR" \
		"$XDG_DATA_HOME/omp" \
		"$XDG_STATE_HOME/omp" \
		"$XDG_CACHE_HOME/omp"
	rw_paths=()
	add_rw_path() {
		rw_paths+=("$1")
	}
	is_known_subcommand "omp"
	configure_agent_subcommand "omp"
	[[ "$command_flag" == "omp" ]]
	[[ ${#rw_paths[@]} -eq 5 ]]
	[[ "${rw_paths[0]}" == "$HOME/.omp" ]]
	[[ "${rw_paths[1]}" == "$PI_CODING_AGENT_DIR" ]]
	[[ "${rw_paths[2]}" == "$XDG_DATA_HOME/omp" ]]
	[[ "${rw_paths[3]}" == "$XDG_STATE_HOME/omp" ]]
	[[ "${rw_paths[4]}" == "$XDG_CACHE_HOME/omp" ]]
); then
	pass "OMP mode registers its command and writable state roots"
else
	fail "OMP mode registers its command and writable state roots"
fi

echo ""
echo "Test: Docker image cleanup lists only old cco registry tags"
if (
	source "$FUNCTIONS_ONLY"
	docker() {
		if [[ "$*" == "image ls ghcr.io/nikvdp/cco --format {{.Repository}}:{{.Tag}}" ]]; then
			printf '%s\n' \
				"ghcr.io/nikvdp/cco:current" \
				"ghcr.io/nikvdp/cco:old-one" \
				"ghcr.io/nikvdp/cco:<none>" \
				"other/repo:old"
			return 0
		fi
		return 1
	}
	output=$(list_old_cco_image_refs "ghcr.io/nikvdp/cco:current")
	[[ "$output" == "ghcr.io/nikvdp/cco:old-one" ]]
); then
	pass "Docker image cleanup lists only old managed registry tags"
else
	fail "Docker image cleanup lists only old managed registry tags"
fi

echo ""
echo "Test: Docker image cleanup auto-removes old tags when flag is set"
if (
	source "$FUNCTIONS_ONLY"
	clean_old_images=true
	removed_refs=()
	list_old_cco_image_refs() {
		printf '%s\n' "ghcr.io/nikvdp/cco:old-one" "ghcr.io/nikvdp/cco:old-two"
	}
	remove_old_cco_images() {
		removed_refs=("$@")
	}
	offer_old_cco_image_cleanup "ghcr.io/nikvdp/cco:current"
	[[ ${#removed_refs[@]} -eq 2 ]]
	[[ "${removed_refs[0]}" == "ghcr.io/nikvdp/cco:old-one" ]]
	[[ "${removed_refs[1]}" == "ghcr.io/nikvdp/cco:old-two" ]]
); then
	pass "Docker image cleanup auto-removes old tags when flag is set"
else
	fail "Docker image cleanup auto-removes old tags when flag is set"
fi

echo ""
echo "Test: Docker image cleanup skips removal without prompt confirmation"
if (
	source "$FUNCTIONS_ONLY"
	clean_old_images=false
	removed_count=0
	list_old_cco_image_refs() {
		printf '%s\n' "ghcr.io/nikvdp/cco:old-one"
	}
	confirm_default_no() {
		return 1
	}
	remove_old_cco_images() {
		removed_count=$((removed_count + $#))
	}
	offer_old_cco_image_cleanup "ghcr.io/nikvdp/cco:current"
	[[ "$removed_count" -eq 0 ]]
); then
	pass "Docker image cleanup skips removal without prompt confirmation"
else
	fail "Docker image cleanup skips removal without prompt confirmation"
fi

echo ""
echo "Test: Claude permission args honor explicit permission mode"
if (
	source "$FUNCTIONS_ONLY"
	claude_args=(--permission-mode auto)
	claude_permission_args=(stale)
	build_claude_permission_args
	[[ ${#claude_permission_args[@]} -eq 0 ]]
); then
	pass "explicit Claude permission mode suppresses default bypass flag"
else
	fail "explicit Claude permission mode suppresses default bypass flag"
fi

echo ""
echo "Test: Claude permission args honor trusted default auto mode"
if (
	source "$FUNCTIONS_ONLY"
	claude_args=()
	claude_permission_args=(stale)
	claude_dir="$TEST_ROOT/auto-mode-claude-config"
	mkdir -p "$claude_dir"
	printf '{"permissions":{"defaultMode":"auto"}}\n' >"$claude_dir/settings.json"
	find_claude_config_dir() {
		printf '%s\n' "$claude_dir"
	}
	build_claude_permission_args
	[[ ${#claude_permission_args[@]} -eq 0 ]]
); then
	pass "trusted default auto mode suppresses default bypass flag"
else
	fail "trusted default auto mode suppresses default bypass flag"
fi

echo ""
echo "Test: Claude permission args keep bypass when auto mode is disabled"
if (
	source "$FUNCTIONS_ONLY"
	claude_args=()
	claude_permission_args=()
	default_settings="$TEST_ROOT/auto-default-settings.json"
	disabled_settings="$TEST_ROOT/auto-disabled-settings.json"
	printf '{"permissions":{"defaultMode":"auto"}}\n' >"$default_settings"
	printf '{"permissions":{"disableAutoMode":"disable"}}\n' >"$disabled_settings"
	trusted_claude_settings_paths() {
		printf '%s\n' "$disabled_settings"
		printf '%s\n' "$default_settings"
	}
	build_claude_permission_args
	[[ ${#claude_permission_args[@]} -eq 1 ]]
	[[ "${claude_permission_args[0]}" == "--dangerously-skip-permissions" ]]
); then
	pass "disabled auto mode keeps default bypass flag"
else
	fail "disabled auto mode keeps default bypass flag"
fi

echo ""
echo "Test: cco auto mode requests Claude --permission-mode auto"
if (
	source "$FUNCTIONS_ONLY"
	auto_mode=true
	claude_args=()
	claude_permission_args=(stale)
	build_claude_permission_args
	[[ ${#claude_permission_args[@]} -eq 2 ]]
	[[ "${claude_permission_args[0]}" == "--permission-mode" ]]
	[[ "${claude_permission_args[1]}" == "auto" ]]
); then
	pass "cco auto mode requests Claude --permission-mode auto"
else
	fail "cco auto mode requests Claude --permission-mode auto"
fi

echo ""
echo "Test: cco auto mode gives Codex --ask-for-approval on-request"
if (
	source "$FUNCTIONS_ONLY"
	auto_mode=true
	codex_mode=true
	command_flag="codex"
	SANDBOX_BACKEND="native"
	claude_args=("hi")
	apply_codex_arg_policies
	[[ "${claude_args[0]}" == "--ask-for-approval" ]]
	[[ "${claude_args[1]}" == "on-request" ]]
	! printf '%s\n' "${claude_args[@]}" | grep -qx -- "--dangerously-bypass-approvals-and-sandbox"
); then
	pass "cco auto mode gives Codex --ask-for-approval on-request"
else
	fail "cco auto mode gives Codex --ask-for-approval on-request"
fi

echo ""
echo "Test: Codex without auto mode keeps the bypass flag"
if (
	source "$FUNCTIONS_ONLY"
	auto_mode=false
	codex_mode=true
	command_flag="codex"
	SANDBOX_BACKEND="native"
	claude_args=("hi")
	apply_codex_arg_policies
	[[ "${claude_args[0]}" == "--dangerously-bypass-approvals-and-sandbox" ]]
); then
	pass "Codex without auto mode keeps the bypass flag"
else
	fail "Codex without auto mode keeps the bypass flag"
fi

echo ""
echo "Test: additionalDirectories is silent when key is absent"
if output=$(
	TEST_ROOT="$TEST_ROOT" FUNCTIONS_ONLY="$FUNCTIONS_ONLY" bash <<'EOF' 2>&1
set -euo pipefail
source "$FUNCTIONS_ONLY"
project_dir="$TEST_ROOT/no-additional-directories-project"
mkdir -p "$project_dir/.claude"
printf '{"permissions":{"defaultMode":"auto"}}\n' >"$project_dir/.claude/settings.local.json"
cd "$project_dir"
additional_dirs=()
load_additional_directories_from_settings
EOF
); then
	if [[ "$output" == *"Skipping additionalDirectories"* ]]; then
		echo "  output:"
		printf '%s\n' "$output" | sed 's/^/    /'
		fail "missing additionalDirectories key produces no warning"
	else
		pass "missing additionalDirectories key produces no warning"
	fi
else
	echo "  output:"
	printf '%s\n' "$output" | sed 's/^/    /'
	fail "missing additionalDirectories key does not fail"
fi

echo ""
echo "Test: OAuth preflight repairs expired credentials before startup"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	yes_flag=false
	allow_keychain=false
	SANDBOX_BACKEND="native"
	payload_file="$TEST_ROOT/oauth_expired_payload.json"
	expired_at=$((($(date +%s) - 60) * 1000))
	fresh_at=4102444800000
	refresh_attempts=0
	printf '{"expiresAt":%s}\n' "$expired_at" >"$payload_file"
	get_claude_credentials_payload() {
		cat "$payload_file"
	}
	run_unsandboxed_claude_refresh() {
		refresh_attempts=$((refresh_attempts + 1))
		printf '{"expiresAt":%s}\n' "$fresh_at" >"$payload_file"
		return 0
	}
	ensure_refreshable_oauth_credentials
	[[ "$refresh_attempts" -eq 1 ]]
	[[ "$(cat "$payload_file")" == '{"expiresAt":4102444800000}' ]]
); then
	pass "OAuth preflight repairs expired credentials before startup"
else
	fail "OAuth preflight repairs expired credentials before startup"
fi

echo ""
echo "Test: OAuth preflight fails closed when expired refresh fails"
if output=$(
	PATH="$FAKE_BIN:$PATH" TEST_ROOT="$TEST_ROOT" FUNCTIONS_ONLY="$FUNCTIONS_ONLY" bash <<'EOF' 2>&1
set -euo pipefail
source "$FUNCTIONS_ONLY"
yes_flag=false
allow_keychain=false
SANDBOX_BACKEND="native"
expired_at=$((($(date +%s) - 60) * 1000))
get_claude_credentials_payload() {
	printf '{"expiresAt":%s}\n' "$expired_at"
}
get_claude_command() {
	printf 'claude\n'
}
run_unsandboxed_claude_refresh() {
	return 1
}
ensure_refreshable_oauth_credentials
EOF
); then
	fail "OAuth preflight exits when expired refresh fails"
else
	assert_contains "$output" "Claude OAuth refresh did not complete" "expired refresh failure explains failure"
	assert_contains "$output" "Run plain \`claude\` to re-authenticate, then retry cco." "expired refresh failure prints reauth guidance"
fi

echo ""
echo "Test: OAuth preflight fails closed when expired refresh remains expired"
if output=$(
	PATH="$FAKE_BIN:$PATH" TEST_ROOT="$TEST_ROOT" FUNCTIONS_ONLY="$FUNCTIONS_ONLY" bash <<'EOF' 2>&1
set -euo pipefail
source "$FUNCTIONS_ONLY"
yes_flag=false
allow_keychain=false
SANDBOX_BACKEND="native"
expired_at=$((($(date +%s) - 60) * 1000))
get_claude_credentials_payload() {
	printf '{"expiresAt":%s}\n' "$expired_at"
}
get_claude_command() {
	printf 'claude\n'
}
run_unsandboxed_claude_refresh() {
	return 0
}
ensure_refreshable_oauth_credentials
EOF
); then
	fail "OAuth preflight exits when refreshed credentials remain expired"
else
	assert_contains "$output" "Claude OAuth credentials are still expired after the refresh attempt" "still-expired refresh explains failure"
	assert_contains "$output" "Run plain \`claude\` to re-authenticate, then retry cco." "still-expired refresh prints reauth guidance"
fi

echo ""
echo "Test: OAuth preflight backgrounds refresh for valid near-expiry credentials"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	yes_flag=false
	allow_keychain=false
	SANDBOX_BACKEND="native"
	background_attempts=0
	foreground_attempts=0
	expires_at=$((($(date +%s) + (90 * 60)) * 1000))
	get_claude_credentials_payload() {
		printf '{"expiresAt":%s}\n' "$expires_at"
	}
	run_unsandboxed_claude_refresh() {
		foreground_attempts=$((foreground_attempts + 1))
		return 1
	}
	start_background_claude_refresh() {
		background_attempts=$((background_attempts + 1))
	}
	ensure_refreshable_oauth_credentials
	[[ "$background_attempts" -eq 1 ]]
	[[ "$foreground_attempts" -eq 0 ]]
); then
	pass "OAuth preflight backgrounds refresh for valid near-expiry credentials"
else
	fail "OAuth preflight backgrounds refresh for valid near-expiry credentials"
fi

echo ""
echo "Test: OAuth preflight skips refresh outside background window"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	yes_flag=false
	allow_keychain=false
	SANDBOX_BACKEND="native"
	background_attempts=0
	foreground_attempts=0
	expires_at=$((($(date +%s) + (3 * 60 * 60)) * 1000))
	get_claude_credentials_payload() {
		printf '{"expiresAt":%s}\n' "$expires_at"
	}
	run_unsandboxed_claude_refresh() {
		foreground_attempts=$((foreground_attempts + 1))
		return 0
	}
	start_background_claude_refresh() {
		background_attempts=$((background_attempts + 1))
	}
	ensure_refreshable_oauth_credentials
	[[ "$background_attempts" -eq 0 ]]
	[[ "$foreground_attempts" -eq 0 ]]
); then
	pass "OAuth preflight skips refresh outside background window"
else
	fail "OAuth preflight skips refresh outside background window"
fi

echo ""
echo "Test: OAuth preflight skips refresh when CLAUDE_CODE_OAUTH_TOKEN is set"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	export CLAUDE_CODE_OAUTH_TOKEN="test-token"
	payload_reads=0
	get_claude_credentials_payload() {
		payload_reads=$((payload_reads + 1))
		return 0
	}
	ensure_refreshable_oauth_credentials
	[[ "$payload_reads" -eq 0 ]]
); then
	pass "OAuth preflight skips refresh when external token is provided"
else
	fail "OAuth preflight skips refresh when external token is provided"
fi

echo ""
echo "Test: OAuth preflight skips refresh when ANTHROPIC_API_KEY is set"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	export ANTHROPIC_API_KEY="test-api-key"
	payload_reads=0
	get_claude_credentials_payload() {
		payload_reads=$((payload_reads + 1))
		return 0
	}
	ensure_refreshable_oauth_credentials
	[[ "$payload_reads" -eq 0 ]]
); then
	pass "OAuth preflight skips refresh when Anthropic API key is provided"
else
	fail "OAuth preflight skips refresh when Anthropic API key is provided"
fi

echo ""
echo "Test: OAuth preflight skips refresh when settings env has ANTHROPIC_AUTH_TOKEN"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	project_dir="$TEST_ROOT/settings-env-auth-project"
	mkdir -p "$project_dir/.claude"
	printf '{"env":{"ANTHROPIC_AUTH_TOKEN":"test-auth-token"}}\n' >"$project_dir/.claude/settings.local.json"
	cd "$project_dir"
	payload_reads=0
	get_claude_credentials_payload() {
		payload_reads=$((payload_reads + 1))
		return 0
	}
	ensure_refreshable_oauth_credentials
	[[ "$payload_reads" -eq 0 ]]
); then
	pass "OAuth preflight skips refresh when settings env has Anthropic auth token"
else
	fail "OAuth preflight skips refresh when settings env has Anthropic auth token"
fi

echo ""
echo "Test: OAuth preflight does not use managed settings in Docker backend"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
	export HOME="$TEST_ROOT/docker-managed-home"
	unset CLAUDE_CONFIG_DIR
	project_dir="$TEST_ROOT/docker-managed-project"
	mkdir -p "$project_dir/.claude" "$HOME/.claude"
	cd "$project_dir"
	SANDBOX_BACKEND="docker"
	managed_settings="$TEST_ROOT/docker-managed-settings.json"
	printf '{"env":{"ANTHROPIC_API_KEY":"managed-api-key"}}\n' >"$managed_settings"
	claude_managed_settings_path() {
		printf '%s\n' "$managed_settings"
	}
	counter_file="$TEST_ROOT/docker-managed-payload-reads"
	get_claude_credentials_payload() {
		printf 'read\n' >>"$counter_file"
		return 0
	}
	ensure_refreshable_oauth_credentials
	[[ "$(wc -l <"$counter_file")" -eq 1 ]]
); then
	pass "Docker backend ignores host managed settings for auth preflight"
else
	fail "Docker backend ignores host managed settings for auth preflight"
fi

echo ""
echo "Test: OAuth preflight honors higher-priority blank settings auth override"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
	export HOME="$TEST_ROOT/blank-auth-override-home"
	unset CLAUDE_CONFIG_DIR
	mkdir -p "$HOME/.claude"
	claude_managed_settings_path() {
		printf '%s\n' "$TEST_ROOT/no-managed-settings.json"
	}
	printf '{"env":{"ANTHROPIC_API_KEY":"user-api-key"}}\n' >"$HOME/.claude/settings.json"
	project_dir="$TEST_ROOT/blank-auth-override-project"
	mkdir -p "$project_dir/.claude"
	printf '{"env":{"ANTHROPIC_API_KEY":"   "}}\n' >"$project_dir/.claude/settings.local.json"
	cd "$project_dir"
	counter_file="$TEST_ROOT/blank-auth-override-payload-reads"
	get_claude_credentials_payload() {
		printf 'read\n' >>"$counter_file"
		return 0
	}
	ensure_refreshable_oauth_credentials
	[[ "$(wc -l <"$counter_file")" -eq 1 ]]
); then
	pass "higher-priority blank settings auth overrides lower-priority value"
else
	fail "higher-priority blank settings auth overrides lower-priority value"
fi

echo ""
echo "Test: OAuth expiry extraction prefers claudeAiOauth over mcpOAuth entries"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	payload='{"mcpOAuth":{"sentry|one":{"expiresAt":0},"other|two":{"expiresAt":0}},"claudeAiOauth":{"expiresAt":1773682299199}}'
	[[ "$(extract_oauth_expiry_ms "$payload")" == "1773682299199" ]]
); then
	pass "OAuth expiry extraction prefers claudeAiOauth over mcpOAuth entries"
else
	fail "OAuth expiry extraction prefers claudeAiOauth over mcpOAuth entries"
fi

echo ""
echo "Test: macOS SSH keychain recovery auto-unlocks when --yes is active"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	yes_flag=true
	export SSH_CONNECTION="ssh-test"
	claude_dir="$TEST_ROOT/claude-config"
	mkdir -p "$claude_dir"
	find_claude_config_dir() {
		printf '%s\n' "$claude_dir"
	}
	keychain_attempts=0
	unlock_attempts=0
	capture_macos_keychain_credentials() {
		keychain_attempts=$((keychain_attempts + 1))
		if [[ "$unlock_attempts" -eq 0 ]]; then
			keychain_credentials_payload=""
			keychain_credentials_error="User interaction is not allowed."
			return 1
		fi
		keychain_credentials_payload='{"accessToken":"ok"}'
		keychain_credentials_error=""
		return 0
	}
	run_macos_keychain_unlock() {
		unlock_attempts=$((unlock_attempts + 1))
		return 0
	}
	verify_claude_authentication
	[[ "$unlock_attempts" -eq 1 ]]
	[[ "$keychain_attempts" -eq 3 ]]
); then
	pass "macOS SSH keychain recovery auto-unlocks with --yes"
else
	fail "macOS SSH keychain recovery auto-unlocks with --yes"
fi

echo ""
echo "Test: auth file checks are skipped when CLAUDE_CODE_OAUTH_TOKEN is set"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	export CLAUDE_CODE_OAUTH_TOKEN="test-token"
	export HOME="$TEST_ROOT/external-token-home"
	unset CLAUDE_CONFIG_DIR
	keychain_attempts=0
	find_claude_config_dir() {
		printf '%s\n' "$TEST_ROOT/missing-claude-config"
	}
	capture_macos_keychain_credentials() {
		keychain_attempts=$((keychain_attempts + 1))
		return 1
	}
	verify_claude_authentication
	[[ "$keychain_attempts" -eq 0 ]]
); then
	pass "auth file checks are skipped when external token is provided"
else
	fail "auth file checks are skipped when external token is provided"
fi

echo ""
echo "Test: auth file checks are skipped when ANTHROPIC_API_KEY is set"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	export ANTHROPIC_API_KEY="test-api-key"
	export HOME="$TEST_ROOT/external-api-key-home"
	unset CLAUDE_CONFIG_DIR
	keychain_attempts=0
	find_claude_config_dir() {
		printf '%s\n' "$TEST_ROOT/missing-api-key-claude-config"
	}
	capture_macos_keychain_credentials() {
		keychain_attempts=$((keychain_attempts + 1))
		return 1
	}
	verify_claude_authentication
	[[ "$keychain_attempts" -eq 0 ]]
); then
	pass "auth file checks are skipped when Anthropic API key is provided"
else
	fail "auth file checks are skipped when Anthropic API key is provided"
fi

echo ""
echo "Test: auth file checks are skipped when .env provides ANTHROPIC_API_KEY"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
	export HOME="$TEST_ROOT/dotenv-api-key-home"
	unset CLAUDE_CONFIG_DIR
	project_dir="$TEST_ROOT/dotenv-api-key-project"
	mkdir -p "$project_dir"
	printf 'ANTHROPIC_API_KEY=dotenv-api-key\n' >"$project_dir/.env"
	cd "$project_dir"
	custom_env_vars=()
	claude_managed_settings_path() {
		printf '%s\n' "$TEST_ROOT/no-managed-settings.json"
	}
	keychain_attempts=0
	capture_macos_keychain_credentials() {
		keychain_attempts=$((keychain_attempts + 1))
		return 1
	}
	apply_preflight_environment
	verify_claude_authentication
	[[ "$keychain_attempts" -eq 0 ]]
); then
	pass "auth file checks are skipped when .env provides Anthropic API key"
else
	fail "auth file checks are skipped when .env provides Anthropic API key"
fi

echo ""
echo "Test: auth file checks are skipped when --env provides ANTHROPIC_API_KEY"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
	export HOME="$TEST_ROOT/custom-env-api-key-home"
	unset CLAUDE_CONFIG_DIR
	project_dir="$TEST_ROOT/custom-env-api-key-project"
	mkdir -p "$project_dir"
	cd "$project_dir"
	custom_env_vars=("ANTHROPIC_API_KEY=custom-env-api-key")
	claude_managed_settings_path() {
		printf '%s\n' "$TEST_ROOT/no-managed-settings.json"
	}
	keychain_attempts=0
	capture_macos_keychain_credentials() {
		keychain_attempts=$((keychain_attempts + 1))
		return 1
	}
	apply_preflight_environment
	verify_claude_authentication
	[[ "$keychain_attempts" -eq 0 ]]
); then
	pass "auth file checks are skipped when --env provides Anthropic API key"
else
	fail "auth file checks are skipped when --env provides Anthropic API key"
fi

echo ""
echo "Test: auth file checks are skipped when project settings env has ANTHROPIC_API_KEY"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	export HOME="$TEST_ROOT/settings-env-api-key-home"
	unset CLAUDE_CONFIG_DIR
	project_dir="$TEST_ROOT/settings-env-api-key-project"
	mkdir -p "$project_dir/.claude"
	printf '{"env":{"ANTHROPIC_API_KEY":"test-api-key"}}\n' >"$project_dir/.claude/settings.json"
	cd "$project_dir"
	keychain_attempts=0
	capture_macos_keychain_credentials() {
		keychain_attempts=$((keychain_attempts + 1))
		return 1
	}
	verify_claude_authentication
	[[ "$keychain_attempts" -eq 0 ]]
); then
	pass "auth file checks are skipped when project settings env has Anthropic API key"
else
	fail "auth file checks are skipped when project settings env has Anthropic API key"
fi

echo ""
echo "Test: auth file checks are skipped when settings.json has apiKeyHelper"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	export HOME="$TEST_ROOT/api-key-helper-home"
	claude_dir="$TEST_ROOT/api-key-helper-claude-config"
	mkdir -p "$claude_dir"
	printf '{"apiKeyHelper":"op read op://claude/api-key"}\n' >"$claude_dir/settings.json"
	find_claude_config_dir() {
		printf '%s\n' "$claude_dir"
	}
	keychain_attempts=0
	capture_macos_keychain_credentials() {
		keychain_attempts=$((keychain_attempts + 1))
		return 1
	}
	verify_claude_authentication
	[[ "$keychain_attempts" -eq 0 ]]
); then
	pass "auth file checks are skipped when apiKeyHelper is configured"
else
	fail "auth file checks are skipped when apiKeyHelper is configured"
fi

echo ""
echo "Test: auth file checks are skipped when project settings has apiKeyHelper"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	export HOME="$TEST_ROOT/project-api-key-helper-home"
	unset CLAUDE_CONFIG_DIR
	project_dir="$TEST_ROOT/project-api-key-helper"
	mkdir -p "$project_dir/.claude"
	printf '{"apiKeyHelper":"op read op://claude/api-key"}\n' >"$project_dir/.claude/settings.json"
	cd "$project_dir"
	keychain_attempts=0
	capture_macos_keychain_credentials() {
		keychain_attempts=$((keychain_attempts + 1))
		return 1
	}
	verify_claude_authentication
	[[ "$keychain_attempts" -eq 0 ]]
); then
	pass "auth file checks are skipped when project apiKeyHelper is configured"
else
	fail "auth file checks are skipped when project apiKeyHelper is configured"
fi

echo ""
echo "Test: file-backed credentials still work when macOS keychain lookup misses"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	yes_flag=false
	claude_dir="$TEST_ROOT/claude-config-file"
	mkdir -p "$claude_dir"
	printf '{"accessToken":"from-file"}\n' >"$claude_dir/.credentials.json"
	find_claude_config_dir() {
		printf '%s\n' "$claude_dir"
	}
	capture_macos_keychain_credentials() {
		keychain_credentials_payload=""
		keychain_credentials_error="security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain."
		return 1
	}
	verify_claude_authentication
	[[ "$(get_claude_credentials_payload)" == '{"accessToken":"from-file"}' ]]
); then
	pass "file-backed credentials work when macOS keychain lookup misses"
else
	fail "file-backed credentials work when macOS keychain lookup misses"
fi

echo ""
echo "Test: macOS SSH keychain failure prints unlock guidance when not auto-accepted"
if output=$(
	PATH="$FAKE_BIN:$PATH" TEST_ROOT="$TEST_ROOT" FUNCTIONS_ONLY="$FUNCTIONS_ONLY" bash <<'EOF' 2>&1
set -euo pipefail
source "$FUNCTIONS_ONLY"
yes_flag=false
export SSH_CONNECTION="ssh-test"
claude_dir="$TEST_ROOT/claude-config-manual"
mkdir -p "$claude_dir"
find_claude_config_dir() {
	printf '%s\n' "$claude_dir"
}
capture_macos_keychain_credentials() {
	keychain_credentials_payload=""
	keychain_credentials_error="User interaction is not allowed."
	return 1
}
verify_claude_authentication
EOF
); then
	fail "macOS SSH keychain failure exits nonzero without --yes"
else
	assert_contains "$output" "Because this session is running over SSH, the login keychain is probably locked" "SSH keychain failure explains likely cause"
	assert_contains "$output" "Run \`security unlock-keychain /tmp/test-login.keychain-db\` and then retry cco." "SSH keychain failure prints unlock command"
fi

echo ""
echo "Test: macOS SSH keychain status fallback still offers unlock guidance"
if output=$(
	PATH="$FAKE_BIN:$PATH" TEST_ROOT="$TEST_ROOT" FUNCTIONS_ONLY="$FUNCTIONS_ONLY" bash <<'EOF' 2>&1
set -euo pipefail
source "$FUNCTIONS_ONLY"
yes_flag=false
export SSH_CONNECTION="ssh-test"
claude_dir="$TEST_ROOT/claude-config-status-fallback"
mkdir -p "$claude_dir"
find_claude_config_dir() {
	printf '%s\n' "$claude_dir"
}
capture_macos_keychain_credentials() {
	keychain_credentials_payload=""
	keychain_credentials_error="security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain."
	return 1
}
macos_login_keychain_appears_locked() {
	return 0
}
verify_claude_authentication
EOF
); then
	fail "macOS SSH keychain status fallback exits nonzero without --yes"
else
	assert_contains "$output" "Because this session is running over SSH, the login keychain is probably locked" "SSH keychain status fallback explains likely cause"
	assert_contains "$output" "Run \`security unlock-keychain /tmp/test-login.keychain-db\` and then retry cco." "SSH keychain status fallback prints unlock command"
fi

echo ""
echo "Test: docker backend receives CLAUDE_CODE_OAUTH_TOKEN from host environment"
if ! supports_docker; then
	skip "docker backend unavailable for external-token passthrough"
elif output=$(
	HOME="$TEST_ROOT/docker-home" CLAUDE_CODE_OAUTH_TOKEN="test-token" \
		"$CCO_BIN" --backend docker shell 'printf %s "$CLAUDE_CODE_OAUTH_TOKEN"' 2>&1
); then
	if [[ "$(printf '%s\n' "$output" | tail -n 1)" == "test-token" ]]; then
		pass "docker backend receives external Claude token"
	else
		echo "  output:"
		printf '%s\n' "$output" | sed 's/^/    /'
		fail "docker backend receives external Claude token"
	fi
else
	echo "  output:"
	printf '%s\n' "$output" | sed 's/^/    /'
	fail "docker backend receives external Claude token"
fi

echo ""
echo "=== Results ==="
echo "Passed:  $PASSED"
echo "Failed:  $FAILED"
echo "Skipped: $SKIPPED"

if [[ $FAILED -gt 0 ]]; then
	exit 1
fi
