#!/usr/bin/env python3
"""
Generate pre-compiled seccomp BPF filters for blocking TIOCSTI/TIOCLINUX.

This script generates the raw BPF bytecode that bwrap --seccomp expects.
It can be run on any platform (macOS, Linux, Windows) to generate the filters.

The output files are architecture-specific because syscall numbers differ.
"""

import struct
import sys
from pathlib import Path

# Seccomp return values
SECCOMP_RET_KILL_PROCESS = 0x80000000
SECCOMP_RET_ERRNO = 0x00050000
SECCOMP_RET_ALLOW = 0x7FFF0000
SECCOMP_RET_DATA = 0x0000FFFF

# BPF instruction components
BPF_LD = 0x00
BPF_JMP = 0x05
BPF_RET = 0x06
BPF_W = 0x00
BPF_ABS = 0x20
BPF_JEQ = 0x10
BPF_JSET = 0x40
BPF_K = 0x00

# Audit architecture values
AUDIT_ARCH_X86_64 = 0xC000003E
AUDIT_ARCH_AARCH64 = 0xC00000B7

# Syscall numbers
NR_IOCTL_X86_64 = 16
NR_IOCTL_AARCH64 = 29

# x32 ABI bit
X32_SYSCALL_BIT = 0x40000000

# Dangerous ioctls
TIOCSTI = 0x5412
TIOCLINUX = 0x541C

# seccomp_data offsets
OFF_NR = 0
OFF_ARCH = 4
OFF_ARG1_LO = 24  # Low 32 bits of args[1] on little-endian

# errno
EPERM = 1


def RET_ERRNO(e):
    return SECCOMP_RET_ERRNO | (e & SECCOMP_RET_DATA)


def bpf_stmt(code, k):
    """Create a BPF statement (no jumps)"""
    return struct.pack("<HBBI", code, 0, 0, k)


def bpf_jump(code, k, jt, jf):
    """Create a BPF jump instruction"""
    return struct.pack("<HBBI", code, jt, jf, k)


def generate_x86_64_filter():
    """Generate BPF filter for x86_64 (includes x32 ABI rejection)"""
    instructions = []

    # [0] Load architecture
    instructions.append(bpf_stmt(BPF_LD | BPF_W | BPF_ABS, OFF_ARCH))

    # [1] Verify architecture == x86_64, else kill
    instructions.append(bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0))

    # [2] Wrong architecture - kill process
    instructions.append(bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS))

    # [3] Load syscall number
    instructions.append(bpf_stmt(BPF_LD | BPF_W | BPF_ABS, OFF_NR))

    # [4] Check x32 ABI bit - if set, deny with EPERM
    instructions.append(bpf_jump(BPF_JMP | BPF_JSET | BPF_K, X32_SYSCALL_BIT, 0, 1))

    # [5] x32 syscall detected - return EPERM
    instructions.append(bpf_stmt(BPF_RET | BPF_K, RET_ERRNO(EPERM)))

    # [6] Check if syscall == ioctl
    instructions.append(bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, NR_IOCTL_X86_64, 1, 0))

    # [7] Not ioctl - allow
    instructions.append(bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW))

    # [8] Load ioctl cmd (arg1, low 32 bits only for security)
    instructions.append(bpf_stmt(BPF_LD | BPF_W | BPF_ABS, OFF_ARG1_LO))

    # [9] Check if cmd == TIOCSTI
    instructions.append(bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, TIOCSTI, 2, 0))

    # [10] Check if cmd == TIOCLINUX
    instructions.append(bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, TIOCLINUX, 1, 0))

    # [11] Not a blocked ioctl - allow
    instructions.append(bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW))

    # [12] Blocked ioctl - return EPERM
    instructions.append(bpf_stmt(BPF_RET | BPF_K, RET_ERRNO(EPERM)))

    return b"".join(instructions)


def generate_aarch64_filter():
    """Generate BPF filter for aarch64 (no x32 ABI)"""
    instructions = []

    # [0] Load architecture
    instructions.append(bpf_stmt(BPF_LD | BPF_W | BPF_ABS, OFF_ARCH))

    # [1] Verify architecture matches, else kill
    instructions.append(bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 1, 0))

    # [2] Wrong architecture - kill process
    instructions.append(bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS))

    # [3] Load syscall number
    instructions.append(bpf_stmt(BPF_LD | BPF_W | BPF_ABS, OFF_NR))

    # [4] Check if syscall == ioctl
    instructions.append(bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, NR_IOCTL_AARCH64, 1, 0))

    # [5] Not ioctl - allow
    instructions.append(bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW))

    # [6] Load ioctl cmd (arg1, low 32 bits only for security)
    instructions.append(bpf_stmt(BPF_LD | BPF_W | BPF_ABS, OFF_ARG1_LO))

    # [7] Check if cmd == TIOCSTI
    instructions.append(bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, TIOCSTI, 2, 0))

    # [8] Check if cmd == TIOCLINUX
    instructions.append(bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, TIOCLINUX, 1, 0))

    # [9] Not a blocked ioctl - allow
    instructions.append(bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW))

    # [10] Blocked ioctl - return EPERM
    instructions.append(bpf_stmt(BPF_RET | BPF_K, RET_ERRNO(EPERM)))

    return b"".join(instructions)


def main():
    script_dir = Path(__file__).parent

    # Generate x86_64 filter
    x86_64_filter = generate_x86_64_filter()
    x86_64_path = script_dir / "tiocsti_filter_x86_64.bpf"
    x86_64_path.write_bytes(x86_64_filter)
    print(
        f"Generated {x86_64_path} ({len(x86_64_filter)} bytes, {len(x86_64_filter) // 8} instructions)"
    )

    # Generate aarch64 filter
    aarch64_filter = generate_aarch64_filter()
    aarch64_path = script_dir / "tiocsti_filter_aarch64.bpf"
    aarch64_path.write_bytes(aarch64_filter)
    print(
        f"Generated {aarch64_path} ({len(aarch64_filter)} bytes, {len(aarch64_filter) // 8} instructions)"
    )

    print("\nTo use with bwrap:")
    print(f"  bwrap --seccomp 3 3<{x86_64_path} [other-options] /bin/sh")


if __name__ == "__main__":
    main()
