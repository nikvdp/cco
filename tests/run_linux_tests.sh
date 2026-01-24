#!/usr/bin/env bash
# Run Linux sandbox tests in Docker (useful for testing Linux from macOS)
# Usage: ./tests/run_linux_tests.sh

set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE_NAME="cco-test-linux"

echo "Building test container..."
docker build -t "$IMAGE_NAME" -f tests/Dockerfile.linux .

echo ""
echo "Running cross-platform sandbox tests..."
docker run --rm --privileged \
	-v "$(pwd):/cco" \
	-w /cco \
	"$IMAGE_NAME" \
	bash tests/test_sandbox.sh

echo ""
echo "Running Linux seccomp tests..."
docker run --rm --privileged \
	-v "$(pwd):/cco" \
	-w /cco \
	"$IMAGE_NAME" \
	bash tests/test_seccomp.sh
