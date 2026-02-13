#!/usr/bin/env bash
# Smoke test for --codex-mode Docker compatibility flags.
# This is a manual/integration test and may require OPENAI_API_KEY + Codex access.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== Smoke Test: codex mode in Docker ==="

if ! command -v docker >/dev/null 2>&1; then
	echo "SKIP: docker is not installed"
	exit 0
fi

if ! docker info >/dev/null 2>&1; then
	echo "SKIP: docker daemon is not running"
	exit 0
fi

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
	echo "SKIP: OPENAI_API_KEY is not set"
	exit 0
fi

echo "Running Codex exec inside cco Docker sandbox with --codex-mode..."

output="$(
	./cco --backend docker --codex-mode shell "
		set -euo pipefail
		tmp_dir=\$(mktemp -d)
		cd \"\$tmp_dir\"
		printf 'SMOKE_OK\n' > SMOKE.txt
		codex exec -s workspace-write 'Read SMOKE.txt and output only its exact contents.'
	" 2>&1
)"

if printf '%s\n' "$output" | grep -q "SMOKE_OK"; then
	echo "PASS: codex exec succeeded and read workspace file in Docker mode"
else
	echo "FAIL: codex exec did not return expected output"
	echo ""
	echo "Captured output:"
	echo "$output"
	exit 1
fi
