#!/usr/bin/env bash
# Test seccomp TIOCSTI/TIOCLINUX blocking in the sandbox
# Run inside the Linux test container

set -euo pipefail

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

# Create test programs
create_test_programs() {
	cat >/tmp/test_tiocsti.c <<'EOF'
#include <sys/ioctl.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#define TIOCSTI 0x5412
int main() {
    char c = 'X';
    if (ioctl(0, TIOCSTI, &c) < 0) {
        if (errno == EPERM) {
            printf("blocked\n");
            return 0;
        }
        printf("error: %s\n", strerror(errno));
        return 2;
    }
    printf("allowed\n");
    return 1;
}
EOF
	gcc -o /tmp/test_tiocsti /tmp/test_tiocsti.c

	cat >/tmp/test_tioclinux.c <<'EOF'
#include <sys/ioctl.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#define TIOCLINUX 0x541c
int main() {
    char arg[2] = {2, 0};
    if (ioctl(0, TIOCLINUX, arg) < 0) {
        if (errno == EPERM) {
            printf("blocked\n");
            return 0;
        }
        printf("error: %s\n", strerror(errno));
        return 2;
    }
    printf("allowed\n");
    return 1;
}
EOF
	gcc -o /tmp/test_tioclinux /tmp/test_tioclinux.c
}

echo "=== Seccomp Filter Tests ==="
echo "Architecture: $(uname -m)"
echo ""

# Test 1: Basic sandbox works
echo "Test 1: Basic sandbox execution"
if ./sandbox -- echo "hello" | grep -q "hello"; then
	pass "Basic sandbox execution"
else
	fail "Basic sandbox execution"
fi

# Test 2: Seccomp filter file exists for this architecture
echo "Test 2: Seccomp filter exists"
arch=$(uname -m)
case "$arch" in
x86_64) filter="seccomp/tiocsti_filter_x86_64.bpf" ;;
aarch64) filter="seccomp/tiocsti_filter_aarch64.bpf" ;;
*) filter="" ;;
esac
if [[ -n "$filter" && -f "$filter" ]]; then
	pass "Seccomp filter exists: $filter"
else
	fail "Seccomp filter missing for $arch"
fi

# Create test programs
echo "Test 3: Compiling test programs"
if create_test_programs 2>/dev/null; then
	pass "Test programs compiled"
else
	fail "Test programs compilation"
	exit 1
fi

# Test 4: TIOCSTI blocked inside sandbox
echo "Test 4: TIOCSTI blocked inside sandbox"
result=$(./sandbox -w /tmp -- /tmp/test_tiocsti 2>/dev/null || true)
if [[ "$result" == "blocked" ]]; then
	pass "TIOCSTI blocked (EPERM)"
else
	fail "TIOCSTI not blocked: $result"
fi

# Test 5: TIOCLINUX blocked inside sandbox
echo "Test 5: TIOCLINUX blocked inside sandbox"
result=$(./sandbox -w /tmp -- /tmp/test_tioclinux 2>/dev/null || true)
if [[ "$result" == "blocked" ]]; then
	pass "TIOCLINUX blocked (EPERM)"
else
	fail "TIOCLINUX not blocked: $result"
fi

# Test 6: Normal commands still work
echo "Test 6: Normal commands work inside sandbox"
if ./sandbox -- ls /dev/null >/dev/null 2>&1; then
	pass "Normal commands work"
else
	fail "Normal commands broken"
fi

# Test 7: File operations work
echo "Test 7: File operations work inside sandbox"
if ./sandbox -w /tmp -- sh -c 'echo test > /tmp/seccomp_test && cat /tmp/seccomp_test' | grep -q "test"; then
	pass "File operations work"
	rm -f /tmp/seccomp_test
else
	fail "File operations broken"
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [[ $FAILED -gt 0 ]]; then
	exit 1
fi
