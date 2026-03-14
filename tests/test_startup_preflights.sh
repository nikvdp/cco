#!/usr/bin/env bash
# Regression tests for startup recovery preflights.
# Covers OAuth refresh prompting, macOS-over-SSH keychain recovery,
# and the global --yes flag.

set -euo pipefail

cd "$(dirname "$0")/.."

CCO_BIN="$PWD/cco"

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
echo "Test: OAuth preflight auto-refreshes when --yes is active"
if (
	PATH="$FAKE_BIN:$PATH"
	source "$FUNCTIONS_ONLY"
	yes_flag=true
	allow_keychain=false
	SANDBOX_BACKEND="native"
	payload_file="$TEST_ROOT/oauth_payload.json"
	printf '{"expiresAt":1}\n' >"$payload_file"
	get_claude_credentials_payload() {
		cat "$payload_file"
	}
	run_unsandboxed_claude_refresh() {
		printf '{"expiresAt":4102444800000}\n' >"$payload_file"
		return 0
	}
	ensure_refreshable_oauth_credentials
	[[ "$(cat "$payload_file")" == '{"expiresAt":4102444800000}' ]]
); then
	pass "OAuth preflight auto-refreshes with --yes"
else
	fail "OAuth preflight auto-refreshes with --yes"
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
	assert_contains "$output" 'Run `security unlock-keychain /tmp/test-login.keychain-db` and then retry cco.' "SSH keychain failure prints unlock command"
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
	assert_contains "$output" 'Run `security unlock-keychain /tmp/test-login.keychain-db` and then retry cco.' "SSH keychain status fallback prints unlock command"
fi

echo ""
echo "=== Results ==="
echo "Passed:  $PASSED"
echo "Failed:  $FAILED"

if [[ $FAILED -gt 0 ]]; then
	exit 1
fi
