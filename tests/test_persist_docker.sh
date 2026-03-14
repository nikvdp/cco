#!/usr/bin/env bash
# Regression tests for Docker --persist behavior.

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

supports_docker() {
	command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

hash_string() {
	local input="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum | awk '{print substr($1, 1, 12)}'
	elif command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
	else
		printf '%s' "$input" | cksum | awk '{print $1}'
	fi
}

sanitize_dir_name() {
	basename "$1" | tr -c '[:alnum:]._-' '_'
}

sanitize_name_fragment() {
	printf '%s' "$1" | tr -c '[:alnum:]._-' '_' | cut -c1-40
}

echo "=== Docker Persist Regression Tests ==="
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
TEST_HOME="$TEST_ROOT/home"
TEST_WORKDIR="$TEST_ROOT/cco-persist-test-$$"
ENV_TEST_WORKDIR="$TEST_ROOT/cco-persist-env-test-$$"
REPO_WORKDIR="$TEST_ROOT/cco-persist-repo-$$"
REPO_WORKTREE="$TEST_ROOT/cco-persist-repo-wt-$$"
mkdir -p "$TEST_HOME" "$TEST_WORKDIR" "$TEST_HOME/.ssh"
mkdir -p "$ENV_TEST_WORKDIR" "$REPO_WORKDIR"

git init "$REPO_WORKDIR" >/dev/null
git -C "$REPO_WORKDIR" config user.email "persist@example.com"
git -C "$REPO_WORKDIR" config user.name "persist"
printf 'persist\n' >"$REPO_WORKDIR/README.md"
git -C "$REPO_WORKDIR" add README.md
git -C "$REPO_WORKDIR" commit -m "init" >/dev/null
git -C "$REPO_WORKDIR" worktree add -b persist-worktree "$REPO_WORKTREE" >/dev/null

PERSIST_CONTAINER_NAME="cco-$(sanitize_dir_name "$TEST_WORKDIR")-persist-$(hash_string "$TEST_WORKDIR")"
ENV_PERSIST_CONTAINER_NAME="cco-$(sanitize_dir_name "$ENV_TEST_WORKDIR")-persist-$(hash_string "$ENV_TEST_WORKDIR")"
ALPHA_CONTAINER_NAME="cco-$(sanitize_dir_name "$TEST_WORKDIR")-persist-$(sanitize_name_fragment "alpha")-$(hash_string "alpha")-$(hash_string "$TEST_WORKDIR")"
BETA_CONTAINER_NAME="cco-$(sanitize_dir_name "$TEST_WORKDIR")-persist-$(sanitize_name_fragment "beta")-$(hash_string "beta")-$(hash_string "$TEST_WORKDIR")"
REPO_PERSIST_CONTAINER_NAME="cco-$(sanitize_dir_name "$REPO_WORKDIR")-persist-$(hash_string "$REPO_WORKDIR")"

cleanup_test_artifacts() {
	docker rm -f "$PERSIST_CONTAINER_NAME" >/dev/null 2>&1 || true
	docker rm -f "$ENV_PERSIST_CONTAINER_NAME" >/dev/null 2>&1 || true
	docker rm -f "$ALPHA_CONTAINER_NAME" >/dev/null 2>&1 || true
	docker rm -f "$BETA_CONTAINER_NAME" >/dev/null 2>&1 || true
	docker rm -f "$REPO_PERSIST_CONTAINER_NAME" >/dev/null 2>&1 || true
	rm -rf "$TEST_ROOT"
}

run_in_test_workdir() {
	(
		cd "$TEST_WORKDIR"
		HOME="$TEST_HOME" "$CCO_BIN" "$@"
	)
}

run_in_env_test_workdir() {
	(
		cd "$ENV_TEST_WORKDIR"
		HOME="$TEST_HOME" "$CCO_BIN" "$@"
	)
}

run_in_repo_workdir() {
	(
		cd "$REPO_WORKDIR"
		HOME="$TEST_HOME" "$CCO_BIN" "$@"
	)
}

run_in_repo_worktree() {
	(
		cd "$REPO_WORKTREE"
		HOME="$TEST_HOME" "$CCO_BIN" "$@"
	)
}

trap cleanup_test_artifacts EXIT

echo "Test: default Docker mode stays ephemeral across invocations"
if run_in_test_workdir --backend docker --command bash -lc \
	'echo ephemeral >/tmp/cco-ephemeral-proof && cat /tmp/cco-ephemeral-proof' \
	>"$TEST_ROOT/ephemeral-first.log" 2>&1; then
	assert_contains "$TEST_ROOT/ephemeral-first.log" "ephemeral" \
		"default Docker run can write inside container"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/ephemeral-first.log"
	fail "default Docker run can write inside container"
fi

if run_in_test_workdir --backend docker --command bash -lc \
	'test ! -e /tmp/cco-ephemeral-proof' \
	>"$TEST_ROOT/ephemeral-second.log" 2>&1; then
	pass "default Docker mode does not reuse container state"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/ephemeral-second.log"
	fail "default Docker mode does not reuse container state"
fi

echo ""
echo "Test: --persist reuses container state"
if run_in_test_workdir --backend docker --persist --command bash -lc \
	'echo first >/tmp/cco-persist-proof && cat /tmp/cco-persist-proof' \
	>"$TEST_ROOT/persist-first.log" 2>&1; then
	assert_contains "$TEST_ROOT/persist-first.log" "first" \
		"persist mode writes inside persistent container"
	assert_contains "$TEST_ROOT/persist-first.log" \
		"Creating persistent container: $PERSIST_CONTAINER_NAME" \
		"persist mode creates a named container on first run"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-first.log"
	fail "persist mode first run succeeds"
fi

if run_in_test_workdir --backend docker --persist --command bash -lc \
	'cat /tmp/cco-persist-proof' \
	>"$TEST_ROOT/persist-second.log" 2>&1; then
	assert_contains "$TEST_ROOT/persist-second.log" "first" \
		"persist mode reuses prior container filesystem state"
	assert_contains "$TEST_ROOT/persist-second.log" \
		"Reusing persistent container: $PERSIST_CONTAINER_NAME" \
		"persist mode reuses existing container on second run"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-second.log"
	fail "persist mode second run succeeds"
fi

echo ""
echo "Test: stopped persistent container is restarted"
if docker stop "$PERSIST_CONTAINER_NAME" >/dev/null 2>&1; then
	pass "test container can be stopped for restart coverage"
else
	fail "test container can be stopped for restart coverage"
fi

if run_in_test_workdir --backend docker --persist --command bash -lc \
	'cat /tmp/cco-persist-proof' \
	>"$TEST_ROOT/persist-third.log" 2>&1; then
	assert_contains "$TEST_ROOT/persist-third.log" "first" \
		"persist mode keeps state after container restart"
	assert_contains "$TEST_ROOT/persist-third.log" \
		"Starting persistent container: $PERSIST_CONTAINER_NAME" \
		"persist mode restarts stopped container"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-third.log"
	fail "persist mode restart run succeeds"
fi

echo ""
echo "Test: --persist rejects config drift"
if run_in_test_workdir --backend docker --persist --deny-path "$TEST_HOME/.ssh" --command true \
	>"$TEST_ROOT/persist-drift.log" 2>&1; then
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-drift.log"
	fail "persist mode rejects config drift"
else
	assert_contains "$TEST_ROOT/persist-drift.log" \
		"Persistent container exists with a different configuration" \
		"persist mode detects config drift"
fi

echo ""
echo "Test: named persist sessions keep separate state"
if run_in_test_workdir --backend docker --persist=alpha --command bash -lc \
	'echo alpha >/tmp/cco-persist-named-proof && cat /tmp/cco-persist-named-proof' \
	>"$TEST_ROOT/persist-alpha-first.log" 2>&1; then
	assert_contains "$TEST_ROOT/persist-alpha-first.log" "alpha" \
		"named persist session alpha writes its own state"
	assert_contains "$TEST_ROOT/persist-alpha-first.log" \
		"Creating persistent container: $ALPHA_CONTAINER_NAME" \
		"named persist session alpha creates its own container"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-alpha-first.log"
	fail "named persist session alpha first run succeeds"
fi

if run_in_test_workdir --backend docker --persist beta --command bash -lc \
	'test ! -e /tmp/cco-persist-named-proof && echo beta >/tmp/cco-persist-named-proof && cat /tmp/cco-persist-named-proof' \
	>"$TEST_ROOT/persist-beta-first.log" 2>&1; then
	assert_contains "$TEST_ROOT/persist-beta-first.log" "beta" \
		"named persist session beta starts from separate state"
	assert_contains "$TEST_ROOT/persist-beta-first.log" \
		"Creating persistent container: $BETA_CONTAINER_NAME" \
		"named persist session beta creates a distinct container"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-beta-first.log"
	fail "named persist session beta first run succeeds"
fi

if run_in_test_workdir --backend docker --persist=alpha --command bash -lc \
	'cat /tmp/cco-persist-named-proof' \
	>"$TEST_ROOT/persist-alpha-second.log" 2>&1; then
	assert_contains "$TEST_ROOT/persist-alpha-second.log" "alpha" \
		"named persist session alpha keeps its own state"
	assert_contains "$TEST_ROOT/persist-alpha-second.log" \
		"Reusing persistent container: $ALPHA_CONTAINER_NAME" \
		"named persist session alpha reuses the same container"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-alpha-second.log"
	fail "named persist session alpha second run succeeds"
fi

if run_in_test_workdir --backend docker --persist beta --command bash -lc \
	'cat /tmp/cco-persist-named-proof' \
	>"$TEST_ROOT/persist-beta-second.log" 2>&1; then
	assert_contains "$TEST_ROOT/persist-beta-second.log" "beta" \
		"named persist session beta keeps separate state"
	assert_contains "$TEST_ROOT/persist-beta-second.log" \
		"Reusing persistent container: $BETA_CONTAINER_NAME" \
		"named persist session beta reuses the same container"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-beta-second.log"
	fail "named persist session beta second run succeeds"
fi

echo ""
echo "Test: bare --persist still leaves known subcommands alone"
if run_in_test_workdir --backend docker --persist shell 'printf subcommand-ok' \
	>"$TEST_ROOT/persist-shell-subcommand.log" 2>&1; then
	assert_contains "$TEST_ROOT/persist-shell-subcommand.log" "subcommand-ok" \
		"persist still allows shell subcommand syntax"
	assert_contains "$TEST_ROOT/persist-shell-subcommand.log" \
		"Reusing persistent container: $PERSIST_CONTAINER_NAME" \
		"persist shell command uses the default project session"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-shell-subcommand.log"
	fail "persist still allows shell subcommand syntax"
fi

echo ""
echo "Test: repo-scoped --persist targets the same session across sibling worktrees"
if run_in_repo_workdir --backend docker --persist --command bash -lc \
	'echo repo >/tmp/cco-repo-persist-proof && cat /tmp/cco-repo-persist-proof' \
	>"$TEST_ROOT/repo-persist-first.log" 2>&1; then
	assert_contains "$TEST_ROOT/repo-persist-first.log" "repo" \
		"repo-scoped persist creates state from the primary worktree"
	assert_contains "$TEST_ROOT/repo-persist-first.log" \
		"Creating persistent container: $REPO_PERSIST_CONTAINER_NAME" \
		"repo-scoped persist uses the repo identity for the default session"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/repo-persist-first.log"
	fail "repo-scoped persist creates state from the primary worktree"
fi

if run_in_repo_worktree --backend docker --persist --command true \
	>"$TEST_ROOT/repo-persist-second.log" 2>&1; then
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/repo-persist-second.log"
	fail "repo-scoped persist should fail clearly when the sibling worktree path is not mounted"
else
	assert_contains "$TEST_ROOT/repo-persist-second.log" \
		"Reusing persistent container: $REPO_PERSIST_CONTAINER_NAME" \
		"repo-scoped persist still targets the same container from a sibling worktree"
	assert_contains "$TEST_ROOT/repo-persist-second.log" \
		"Persistent container does not expose the current working directory" \
		"repo-scoped persist fails clearly when the sibling worktree path is unavailable"
fi

echo ""
echo "Test: --persist-container attaches to an existing container by name or ID"
if run_in_test_workdir --backend docker --persist-container "$ALPHA_CONTAINER_NAME" --command bash -lc \
	'cat /tmp/cco-persist-named-proof' \
	>"$TEST_ROOT/persist-container-name.log" 2>&1; then
	assert_contains "$TEST_ROOT/persist-container-name.log" "alpha" \
		"persist-container can attach by container name"
	assert_contains "$TEST_ROOT/persist-container-name.log" \
		"Using persistent container: $ALPHA_CONTAINER_NAME" \
		"persist-container logs the resolved container name"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-container-name.log"
	fail "persist-container can attach by container name"
fi

ALPHA_CONTAINER_ID=$(docker inspect -f '{{.Id}}' "$ALPHA_CONTAINER_NAME")
if run_in_test_workdir --backend docker --persist-container "$ALPHA_CONTAINER_ID" --command bash -lc \
	'cat /tmp/cco-persist-named-proof' \
	>"$TEST_ROOT/persist-container-id.log" 2>&1; then
	assert_contains "$TEST_ROOT/persist-container-id.log" "alpha" \
		"persist-container can attach by container ID"
	assert_contains "$TEST_ROOT/persist-container-id.log" \
		"Using persistent container: $ALPHA_CONTAINER_NAME" \
		"persist-container resolves container IDs back to the canonical name"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-container-id.log"
	fail "persist-container can attach by container ID"
fi

echo ""
echo "Test: --persist-container fails clearly for missing or incompatible targets"
if run_in_test_workdir --backend docker --persist-container cco-no-such-container --command true \
	>"$TEST_ROOT/persist-container-missing.log" 2>&1; then
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-container-missing.log"
	fail "persist-container should fail when the target container is missing"
else
	assert_contains "$TEST_ROOT/persist-container-missing.log" \
		"Persistent container not found: cco-no-such-container" \
		"persist-container reports missing targets clearly"
fi

if run_in_repo_worktree --backend docker --persist-container "$ALPHA_CONTAINER_NAME" --command true \
	>"$TEST_ROOT/persist-container-workdir.log" 2>&1; then
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-container-workdir.log"
	fail "persist-container should fail when the target container does not expose the current worktree"
else
	assert_contains "$TEST_ROOT/persist-container-workdir.log" \
		"Persistent container does not expose the current working directory" \
		"persist-container reports unavailable workdirs clearly"
fi

echo ""
echo "Test: --persist rejects .env drift"
printf 'PERSIST_TEST_ENV=one\n' >"$ENV_TEST_WORKDIR/.env"
# shellcheck disable=SC2016  # Intentional: expand inside the container shell, not in this test process.
if run_in_env_test_workdir --backend docker --persist --command bash -lc \
	'printf %s "$PERSIST_TEST_ENV"' \
	>"$TEST_ROOT/persist-env-first.log" 2>&1; then
	assert_contains "$TEST_ROOT/persist-env-first.log" "one" \
		"persist mode loads .env on first run"
else
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-env-first.log"
	fail "persist mode loads .env on first run"
fi

printf 'PERSIST_TEST_ENV=two\n' >"$ENV_TEST_WORKDIR/.env"
if run_in_env_test_workdir --backend docker --persist --command true \
	>"$TEST_ROOT/persist-env-drift.log" 2>&1; then
	echo "  output:"
	sed 's/^/    /' "$TEST_ROOT/persist-env-drift.log"
	fail "persist mode rejects .env drift"
else
	assert_contains "$TEST_ROOT/persist-env-drift.log" \
		"Persistent container exists with a different configuration" \
		"persist mode detects .env drift"
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Skipped: $SKIPPED"

if [[ $FAILED -gt 0 ]]; then
	exit 1
fi
