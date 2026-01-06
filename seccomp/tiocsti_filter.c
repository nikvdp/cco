/*
 * tiocsti_filter.c - Generate seccomp BPF filter to block TIOCSTI/TIOCLINUX
 *
 * This file has ALL constants inlined - no kernel headers required.
 * Only needs a C compiler (cc/gcc/clang) to build.
 *
 * Compile: cc -O2 -o tiocsti_filter tiocsti_filter.c
 * Usage:   ./tiocsti_filter /path/to/output.bpf
 *          bwrap --seccomp 3 3</path/to/output.bpf ...
 *
 * Security considerations addressed:
 * - 32-bit ioctl cmd masking (prevents high-bit bypass CVE-2019-10063)
 * - x32 ABI rejection on x86_64 (syscall number offset 0x40000000)
 * - Blocks both TIOCSTI and TIOCLINUX (CVE-2023-1523)
 * - Architecture validation (prevents syscall confusion attacks)
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

/*
 * =============================================================================
 * ALL CONSTANTS INLINED - NO KERNEL HEADERS REQUIRED
 * These are stable Linux UAPI constants that haven't changed in 10+ years
 * =============================================================================
 */

/* Seccomp return values (from linux/seccomp.h) */
#define SECCOMP_RET_KILL_PROCESS 0x80000000U
#define SECCOMP_RET_ERRNO        0x00050000U
#define SECCOMP_RET_ALLOW        0x7fff0000U
#define SECCOMP_RET_DATA         0x0000ffffU

/* BPF instruction classes and modes (from linux/bpf_common.h, linux/filter.h) */
#define BPF_LD   0x00
#define BPF_JMP  0x05
#define BPF_RET  0x06
#define BPF_W    0x00
#define BPF_ABS  0x20
#define BPF_JEQ  0x10
#define BPF_JSET 0x40
#define BPF_K    0x00

/* Audit architecture values (from linux/audit.h) */
/* These encode: (EM_machine) | (__AUDIT_ARCH_64BIT) | (__AUDIT_ARCH_LE) */
#define AUDIT_ARCH_X86_64   0xc000003eU  /* EM_X86_64 | 64BIT | LE */
#define AUDIT_ARCH_AARCH64  0xc00000b7U  /* EM_AARCH64 | 64BIT | LE */
#define AUDIT_ARCH_I386     0x40000003U  /* EM_386 | LE */
#define AUDIT_ARCH_ARM      0x40000028U  /* EM_ARM | LE */

/* Syscall numbers - architecture specific */
#define __NR_ioctl_x86_64   16
#define __NR_ioctl_aarch64  29
#define __NR_ioctl_i386     54
#define __NR_ioctl_arm      54

/* x32 ABI syscall bit (x86_64 only) */
#define X32_SYSCALL_BIT     0x40000000U

/* Dangerous ioctls to block */
#define TIOCSTI   0x5412  /* Inject char into terminal input - sandbox escape */
#define TIOCLINUX 0x541c  /* Virtual console input injection - CVE-2023-1523 */

/*
 * struct sock_filter - BPF instruction (from linux/filter.h)
 * Each instruction is 8 bytes
 */
struct sock_filter {
    uint16_t code;   /* BPF opcode */
    uint8_t  jt;     /* Jump if true */
    uint8_t  jf;     /* Jump if false */
    uint32_t k;      /* Constant/offset */
};

/*
 * seccomp_data layout offsets (from linux/seccomp.h)
 *
 * struct seccomp_data {
 *     int   nr;         // offset 0:  syscall number (32-bit)
 *     __u32 arch;       // offset 4:  AUDIT_ARCH_* value
 *     __u64 ip;         // offset 8:  instruction pointer
 *     __u64 args[6];    // offset 16: syscall arguments (64-bit each)
 * };
 *
 * args[1] is at offset 24 (ioctl cmd argument)
 * We load only the low 32 bits to handle 64-bit bypass attempts
 */
#define OFF_NR       0
#define OFF_ARCH     4
#define OFF_ARG1_LO  24  /* Low 32 bits of args[1] on little-endian */

/* BPF instruction macros */
#define BPF_STMT(code, k) \
    { (uint16_t)(code), 0, 0, (uint32_t)(k) }

#define BPF_JUMP(code, k, jt, jf) \
    { (uint16_t)(code), (uint8_t)(jt), (uint8_t)(jf), (uint32_t)(k) }

/* Return value helpers */
#define RET_ALLOW       SECCOMP_RET_ALLOW
#define RET_KILL        SECCOMP_RET_KILL_PROCESS
#define RET_ERRNO(e)    (SECCOMP_RET_ERRNO | ((e) & SECCOMP_RET_DATA))

/*
 * Detect architecture at compile time
 */
#if defined(__x86_64__)
    #define CURRENT_ARCH    AUDIT_ARCH_X86_64
    #define CURRENT_IOCTL   __NR_ioctl_x86_64
    #define ARCH_NAME       "x86_64"
    #define HAS_X32_ABI     1
#elif defined(__aarch64__)
    #define CURRENT_ARCH    AUDIT_ARCH_AARCH64
    #define CURRENT_IOCTL   __NR_ioctl_aarch64
    #define ARCH_NAME       "aarch64"
    #define HAS_X32_ABI     0
#elif defined(__i386__)
    #define CURRENT_ARCH    AUDIT_ARCH_I386
    #define CURRENT_IOCTL   __NR_ioctl_i386
    #define ARCH_NAME       "i386"
    #define HAS_X32_ABI     0
#elif defined(__arm__)
    #define CURRENT_ARCH    AUDIT_ARCH_ARM
    #define CURRENT_IOCTL   __NR_ioctl_arm
    #define ARCH_NAME       "arm"
    #define HAS_X32_ABI     0
#else
    #error "Unsupported architecture. Supported: x86_64, aarch64, i386, arm"
#endif

/*
 * =============================================================================
 * BPF FILTER PROGRAM
 * =============================================================================
 *
 * Logic flow:
 * 1. Load and validate architecture
 * 2. [x86_64 only] Reject x32 ABI syscalls
 * 3. Check if syscall is ioctl
 * 4. If ioctl, load cmd argument (low 32 bits only!)
 * 5. Block TIOCSTI (0x5412) and TIOCLINUX (0x541c)
 * 6. Allow everything else
 */

#if HAS_X32_ABI
/*
 * x86_64 filter - includes x32 ABI rejection
 * 
 * The x32 ABI uses syscall numbers with bit 30 set (0x40000000).
 * We must reject these to prevent bypass via x32 ioctl.
 */
static struct sock_filter filter[] = {
    /* [0] Load architecture */
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, OFF_ARCH),
    
    /* [1] Verify architecture == x86_64, else kill */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, CURRENT_ARCH, 1, 0),
    
    /* [2] Wrong architecture - kill process */
    BPF_STMT(BPF_RET | BPF_K, RET_KILL),
    
    /* [3] Load syscall number */
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, OFF_NR),
    
    /* [4] Check x32 ABI bit - if set, deny with EPERM */
    BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, X32_SYSCALL_BIT, 0, 1),
    
    /* [5] x32 syscall detected - return EPERM */
    BPF_STMT(BPF_RET | BPF_K, RET_ERRNO(EPERM)),
    
    /* [6] Check if syscall == ioctl */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, CURRENT_IOCTL, 1, 0),
    
    /* [7] Not ioctl - allow */
    BPF_STMT(BPF_RET | BPF_K, RET_ALLOW),
    
    /* [8] Load ioctl cmd (arg1, low 32 bits only for security) */
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, OFF_ARG1_LO),
    
    /* [9] Check if cmd == TIOCSTI */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, TIOCSTI, 2, 0),
    
    /* [10] Check if cmd == TIOCLINUX */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, TIOCLINUX, 1, 0),
    
    /* [11] Not a blocked ioctl - allow */
    BPF_STMT(BPF_RET | BPF_K, RET_ALLOW),
    
    /* [12] Blocked ioctl - return EPERM */
    BPF_STMT(BPF_RET | BPF_K, RET_ERRNO(EPERM)),
};

#else
/*
 * Non-x86_64 filter (aarch64, i386, arm) - no x32 ABI
 */
static struct sock_filter filter[] = {
    /* [0] Load architecture */
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, OFF_ARCH),
    
    /* [1] Verify architecture matches, else kill */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, CURRENT_ARCH, 1, 0),
    
    /* [2] Wrong architecture - kill process */
    BPF_STMT(BPF_RET | BPF_K, RET_KILL),
    
    /* [3] Load syscall number */
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, OFF_NR),
    
    /* [4] Check if syscall == ioctl */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, CURRENT_IOCTL, 1, 0),
    
    /* [5] Not ioctl - allow */
    BPF_STMT(BPF_RET | BPF_K, RET_ALLOW),
    
    /* [6] Load ioctl cmd (arg1, low 32 bits only for security) */
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, OFF_ARG1_LO),
    
    /* [7] Check if cmd == TIOCSTI */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, TIOCSTI, 2, 0),
    
    /* [8] Check if cmd == TIOCLINUX */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, TIOCLINUX, 1, 0),
    
    /* [9] Not a blocked ioctl - allow */
    BPF_STMT(BPF_RET | BPF_K, RET_ALLOW),
    
    /* [10] Blocked ioctl - return EPERM */
    BPF_STMT(BPF_RET | BPF_K, RET_ERRNO(EPERM)),
};
#endif

#define FILTER_LEN (sizeof(filter) / sizeof(filter[0]))

int main(int argc, char *argv[]) {
    FILE *fp;
    size_t written;

    if (argc != 2) {
        fprintf(stderr, "Usage: %s <output-file>\n\n", argv[0]);
        fprintf(stderr, "Generates a seccomp BPF filter that blocks TIOCSTI and TIOCLINUX ioctls.\n");
        fprintf(stderr, "The output file can be used with bubblewrap's --seccomp option.\n\n");
        fprintf(stderr, "Example:\n");
        fprintf(stderr, "  %s /tmp/filter.bpf\n", argv[0]);
        fprintf(stderr, "  bwrap --seccomp 3 3</tmp/filter.bpf --ro-bind / / /bin/sh\n");
        return 1;
    }

    printf("Generating seccomp BPF filter for TIOCSTI/TIOCLINUX blocking\n");
    printf("  Architecture:    %s\n", ARCH_NAME);
    printf("  Audit arch:      0x%08x\n", CURRENT_ARCH);
    printf("  ioctl syscall:   %d\n", CURRENT_IOCTL);
    printf("  TIOCSTI:         0x%04x\n", TIOCSTI);
    printf("  TIOCLINUX:       0x%04x\n", TIOCLINUX);
#if HAS_X32_ABI
    printf("  x32 ABI:         blocked\n");
#endif
    printf("  Instructions:    %zu\n", FILTER_LEN);
    printf("  Filter size:     %zu bytes\n", sizeof(filter));

    fp = fopen(argv[1], "wb");
    if (!fp) {
        fprintf(stderr, "Error: Cannot open '%s': %s\n", argv[1], strerror(errno));
        return 1;
    }

    written = fwrite(filter, sizeof(struct sock_filter), FILTER_LEN, fp);
    if (written != FILTER_LEN) {
        fprintf(stderr, "Error: Write failed: %s\n", strerror(errno));
        fclose(fp);
        return 1;
    }

    fclose(fp);
    printf("Successfully wrote filter to: %s\n", argv[1]);

    return 0;
}
