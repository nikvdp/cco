.PHONY: help test-install clean format lint

SHELL_FILES = cco sandbox install.sh docker-entrypoint.sh \
              tests/run_linux_tests.sh tests/test_sandbox.sh \
              tests/test_seatbelt_precedence.sh tests/test_seccomp.sh

# Default target
help:
	@echo "cco Development Tasks"
	@echo ""
	@echo "  format        Format all shell scripts with shfmt"
	@echo "  lint          Lint all shell scripts with shellcheck"
	@echo "  test-install  Test curl | bash installer (starts server, tests, cleans up)"
	@echo "  clean         Clean up test files"
	@echo "  help          Show this help message"

# Format shell scripts
format:
	shfmt -w $(SHELL_FILES)

# Lint shell scripts
lint:
	shellcheck $(SHELL_FILES)

# Test the curl | bash installer with local server
test-install:
	@echo "Testing curl | bash installer..."
	@echo "Starting local server on port 5004..."
	@# Start server in background, save PID
	python3 -m http.server 5004 & echo $$! > /tmp/cco-server.pid
	@sleep 2  # Give server time to start
	@echo "Testing installer..."
	curl -fsSL http://localhost:5004/install.sh > /tmp/cco-test-install.sh
	bash /tmp/cco-test-install.sh
	@echo ""
	@echo "Cleaning up..."
	@# Kill the server
	kill `cat /tmp/cco-server.pid` 2>/dev/null || true
	rm -f /tmp/cco-server.pid /tmp/cco-test-install.sh
	@echo "Installation test complete!"

# Clean up test files
clean:
	@echo "Cleaning up test files..."
	@# Kill any running server
	kill `cat /tmp/cco-server.pid` 2>/dev/null || true
	rm -f /tmp/cco-server.pid /tmp/cco-test-install.sh
	@echo "Cleanup complete"
