#!/usr/bin/env bash
# Tests for --env / -e flag in native sandbox backend (issue #22)
# Verifies that custom environment variables are passed into the sandbox.

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

echo "=== Environment Variable Tests (--env flag) ==="
echo "Platform: $(uname -s) ($(uname -m))"
echo ""

# Setup
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

#
# KEY=VALUE format
#

echo "--- KEY=VALUE format ---"

echo "Test: -e KEY=VALUE sets variable in sandbox"
# shellcheck disable=SC2016
if output=$(./cco -e MY_TEST_VAR=hello_world shell 'echo $MY_TEST_VAR') && [[ "$output" == "hello_world" ]]; then
	pass "-e KEY=VALUE sets variable in sandbox"
else
	fail "-e KEY=VALUE sets variable in sandbox: got '$output'"
fi

echo "Test: Multiple -e KEY=VALUE flags"
# shellcheck disable=SC2016
if output=$(./cco -e VAR_A=alpha -e VAR_B=beta shell 'echo ${VAR_A}_${VAR_B}') && [[ "$output" == "alpha_beta" ]]; then
	pass "Multiple -e KEY=VALUE flags"
else
	fail "Multiple -e KEY=VALUE flags: got '$output'"
fi

echo "Test: -e KEY=VALUE with special characters"
# shellcheck disable=SC2016
if output=$(./cco -e 'SPECIAL_VAR=hello world' shell 'echo $SPECIAL_VAR') && [[ "$output" == "hello world" ]]; then
	pass "-e KEY=VALUE with spaces in value"
else
	fail "-e KEY=VALUE with spaces in value: got '$output'"
fi

#
# KEY-only format (pass through from host)
#

echo ""
echo "--- KEY-only format (host passthrough) ---"

echo "Test: -e KEY passes host variable into sandbox"
# shellcheck disable=SC2016
if output=$(HOST_PASSTHROUGH=from_host ./cco -e HOST_PASSTHROUGH shell 'echo $HOST_PASSTHROUGH') && [[ "$output" == "from_host" ]]; then
	pass "-e KEY passes host variable into sandbox"
else
	fail "-e KEY passes host variable into sandbox: got '$output'"
fi

echo "Test: -e KEY with unset host variable is silently ignored"
# shellcheck disable=SC2016
if output=$(
	unset NONEXISTENT_VAR
	./cco -e NONEXISTENT_VAR shell 'echo ">${NONEXISTENT_VAR:-}<"'
) && [[ "$output" == "><" ]]; then
	pass "-e KEY with unset host variable is silently ignored"
else
	fail "-e KEY with unset host variable: got '$output'"
fi

#
# .env file loading
#

echo ""
echo "--- .env file loading ---"

echo "Test: .env file variables are loaded in sandbox"
echo 'DOTENV_TEST=it_works' >"$TEST_DIR/.env"
# shellcheck disable=SC2016
if output=$(cd "$TEST_DIR" && "$OLDPWD/cco" shell 'echo $DOTENV_TEST') && [[ "$output" == "it_works" ]]; then
	pass ".env file variables are loaded in sandbox"
else
	fail ".env file variables are loaded in sandbox: got '$output'"
fi

echo "Test: .env file skips comments and blank lines"
cat >"$TEST_DIR/.env" <<'EOF'
# This is a comment
FIRST_VAR=one

SECOND_VAR=two
# Another comment
EOF
# shellcheck disable=SC2016
if output=$(cd "$TEST_DIR" && "$OLDPWD/cco" shell 'echo ${FIRST_VAR}_${SECOND_VAR}') && [[ "$output" == "one_two" ]]; then
	pass ".env file skips comments and blank lines"
else
	fail ".env file skips comments and blank lines: got '$output'"
fi

echo "Test: -e flag takes precedence over .env file"
echo 'OVERRIDE_VAR=from_dotenv' >"$TEST_DIR/.env"
# shellcheck disable=SC2016
if output=$(cd "$TEST_DIR" && "$OLDPWD/cco" -e OVERRIDE_VAR=from_flag shell 'echo $OVERRIDE_VAR') && [[ "$output" == "from_flag" ]]; then
	pass "-e flag takes precedence over .env file"
else
	# .env is loaded after custom_env_vars, so .env may override -e.
	# If that's the current behavior, note it but don't fail.
	if [[ "$output" == "from_dotenv" ]]; then
		fail "-e flag does NOT take precedence over .env (got .env value)"
	else
		fail "-e flag precedence: got '$output'"
	fi
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
