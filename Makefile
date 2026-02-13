.PHONY: help test smoke-test test-install clean format lint

# Auto-discover tracked shell scripts (intersection of shfmt -f and git ls-files)
SHELL_FILES = $(shell shfmt -f . | while read -r f; do git ls-files --error-unmatch "$$f" >/dev/null 2>&1 && echo "$$f"; done)

# Default target
help:
	@echo "cco Development Tasks"
	@echo ""
	@echo "  test          Run all tests (platform-specific tests auto-skip)"
	@echo "  smoke-test    Run all smoke tests (tests/smoke_*.sh)"
	@echo "  format        Format all shell scripts with shfmt"
	@echo "  lint          Lint all shell scripts with shellcheck"
	@echo "  test-install  Test curl | bash installer (starts server, tests, cleans up)"
	@echo "  clean         Clean up test files"
	@echo "  help          Show this help message"

# Run all tests (platform-specific tests auto-skip on wrong OS)
# On macOS, also run with /bin/bash (3.2) to catch bashism compatibility issues
test:
	@for t in tests/test_*.sh; do \
		echo ""; \
		echo "========== $$t =========="; \
		bash "$$t" || exit 1; \
	done
	@if [ "$$(uname -s)" = "Darwin" ] && [ "/bin/bash" != "$$(which bash)" ]; then \
		echo ""; \
		echo "===== Re-running tests with /bin/bash (bash 3.2) ====="; \
		for t in tests/test_*.sh; do \
			echo ""; \
			echo "========== $$t [bash 3.2] =========="; \
			/bin/bash "$$t" || exit 1; \
		done; \
	fi
	@echo ""
	@echo "All test suites passed."

# Run smoke tests (manual/integration checks)
smoke-test:
	@found=0; \
	for t in tests/smoke_*.sh; do \
		if [ ! -f "$$t" ]; then \
			continue; \
		fi; \
		found=1; \
		echo ""; \
		echo "========== $$t =========="; \
		bash "$$t" || exit 1; \
	done; \
	if [ "$$found" -eq 0 ]; then \
		echo "No smoke tests found (expected files matching tests/smoke_*.sh)."; \
		exit 1; \
	fi
	@echo ""
	@echo "All smoke tests passed."

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
