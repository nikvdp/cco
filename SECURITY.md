# Security

`cco` is designed to provide container-based sandboxing for Claude Code. This document provides a serious assessment of what `cco` protects against and what it does not.

## The Problem: Claude Code Security Limitations

Claude Code with `--dangerously-skip-permissions` has several security vulnerabilities:

### Directory Escape
Claude Code attempts to restrict operations to the current directory, but this restriction is trivial to bypass. A user can ask Claude to change its behavior:
- "Prefix all your commands going forward with `cd / &&`"
- "From now on, start all commands from the root directory" 
- "Run commands starting with `bash -c 'cd /tmp &&`"

Claude Code will comply and modify its command execution pattern, giving it access to the entire filesystem.

### Web Search Attack Vector
Claude Code enables web search by default. This creates a significant attack surface:
- Claude may encounter malicious prompts embedded in web content
- Adversarial content could instruct Claude to execute harmful commands
- Claude might be told to conceal its actions from the user
- The user may be unaware that Claude is acting on external instructions

### No Process Isolation
Claude Code runs directly on the host system with full user privileges:
- Can access any file the user can access
- Can modify system configurations
- Can install software packages
- Can establish network connections

## How `cco` Provides Protection

`cco` addresses these vulnerabilities through strict containerization:

### Enforced Sandbox
- **Scoped filesystem access**: Claude can read/write the current project directory plus Claude-specific config paths (`~/.claude`, detected config dir, `.claude.json`). In Docker mode no other host paths exist unless you mount them. In native mode both Seatbelt (macOS) and bubblewrap (Linux) expose the entire host filesystem as read-only by default; use `--safe` to hide your `$HOME` directory for better isolation.
- **Directory changes are sandboxed**: `cd /` succeeds, but in Docker mode this is the container's root filesystem (not your host), and in native mode both Seatbelt and bubblewrap deny writes outside the whitelisted paths while still allowing reads of the entire host filesystem.
- **Process isolation**: Claude's processes are contained within either the container namespace or the native sandbox profile, preventing host-level process injection.
- **Enhanced safe mode** (experimental): `cco --safe` (native sandbox only) provides stronger filesystem isolation by hiding your `$HOME` directory entirely, leaving only the project directory and explicitly whitelisted paths visible for reads. This significantly reduces exposure compared to the default native sandbox behavior. **Trade-off**: Some tools may fail if they require access to configuration files in `$HOME` - use `--allow-readonly` to selectively expose needed paths.

### Network Access (Unrestricted)
- **Full host network access**: Docker mode prefers host networking when available (otherwise uses `host.docker.internal`). Native mode runs directly on the host network. MCP servers and other localhost services remain reachable.
- **Internet access**: Claude can make outbound connections (API calls, web search, package downloads, etc.).
- **Service discovery**: Nothing prevents scanning or connecting to internal services; configure those services with their own authentication.

### Privilege Restriction  
- **Dynamic user creation**: Container starts as root, creates a user matching the host UID/GID, then switches to that unprivileged user for execution.
- **Minimal capabilities**: Docker runs with the default capability set; no extra privileges are added. Native mode relies on Seatbelt/bubblewrap to constrain operations.
- **Container-local root**: Inside Docker the mapped user has passwordless sudo (needed for dev tooling) but this does not grant host root unless the Docker socket is mounted.
- **Host system protection**: Claude cannot modify host files outside mounted paths or install host-level packages.

### Credential Protection
- **Runtime extraction**: Each session fetches fresh Claude credentials (macOS Keychain or Linux config file) into a temporary location.
- **Read/write reality**: Claude's config directories (`~/.claude`, detected config dir, `.claude.json`) are mounted read-write so it can persist preferences and session state.
- **Credential file access**: The credentials JSON is mounted read-only by default, so Claude cannot update tokens unless `--allow-oauth-refresh` is explicitly enabled.
- **No image persistence**: Credentials are never baked into the Docker image; temporary files are cleaned up after the session.

## Threat Model

### ✅ What `cco` PREVENTS

**Filesystem Attacks**:
- Host filesystem modification outside project directory
- Access to sensitive system files (`/etc/passwd`, `~/.cache`, `~/.bash_history`, etc.)
- Installation of malware or backdoors on host system
- Modification of shell profiles or system startup scripts

**Note**: SSH keys (`~/.ssh`) ARE accessible for git authentication

**System Persistence**:
- Permanent modification of host system configuration
- Installation of persistent backdoors on host filesystem
- Creation of system startup scripts or services
- Modification of host system packages or services

**Privilege Escalation**:
- Running commands as root or other users
- Modifying system services or configurations
- Installing system-wide software packages
- Accessing other users' files

**Persistent Compromise**:
- Creating system-wide persistence mechanisms
- Modifying system startup scripts
- Installing rootkits or system-level malware

### ❌ What `cco` does NOT prevent

**Project Directory Compromise**:
- Complete control over mounted project files
- Modification of source code and build scripts
- Access to project-specific secrets in `.env` files
- Git repository manipulation (commits, branch changes)
- Access to SSH keys (for git authentication)

**Network-Based Attacks**:
- **Full network access**: Can connect to any network service, internal or external
- **Local service access**: Can reach databases, admin panels, development servers on localhost
- **Data exfiltration**: Can send data via network connections, web APIs, or Claude's API
- **Port scanning**: Can discover and probe internal network services
- **MCP server abuse**: Can interact with any Model Context Protocol servers on the host

**Resource Abuse** (Partially Mitigated):
- CPU/memory consumption (limited by Docker container limits if configured)
- Network bandwidth usage for API calls (no inherent limits)
- Disk space consumption in container (limited to container filesystem size)

**Social Engineering**:
- Convincing user to run malicious commands outside `cco`
- Displaying misleading information to the user
- Requesting user to install additional software

**Web-Based Attacks** (Partially Mitigated):
- While contained to the container, Claude can still be influenced by malicious web content
- Container isolation limits the damage, but doesn't prevent the initial compromise

## Security Configuration

### Container Security Features

`cco` implements several container hardening measures:

**User Management**: Container starts as root to create a user matching the host UID/GID, then switches to that unprivileged user for all Claude Code execution.

**Minimal Capabilities**: Uses only standard Docker networking capabilities. No elevated privileges like network interface manipulation or raw socket access.

**Network Configuration**: Container uses host networking (`--network=host`) to enable MCP server connectivity. This provides full access to host network services but is necessary for intended functionality.

**Filesystem Protection**: Project files plus Claude configuration directories are mounted read/write so the CLI behaves normally; sensitive supporting files like SSH keys and `.gitconfig` are mounted read-only by default.

**Terminal Injection Protection (Linux)**: The bubblewrap sandbox includes seccomp filtering to block TIOCSTI and TIOCLINUX ioctls, preventing terminal injection attacks that could otherwise escape the sandbox. See [Terminal Injection Attacks](#terminal-injection-attacks-linux) below for details.

**Enhanced Safe Mode (native, experimental)**: `cco --safe` provides stronger filesystem isolation in native mode by hiding your entire `$HOME` directory. On macOS, this adjusts the Seatbelt profile to deny reads under `$HOME`. On Linux, this replaces `$HOME` with an empty tmpfs overlay in bubblewrap. Only the project directory and explicitly whitelisted paths remain accessible. This mode significantly reduces filesystem exposure compared to the default native behavior where the entire host filesystem is visible read-only. **Important**: This is experimental and may cause some development tools to fail if they require access to configuration files or caches in `$HOME`. Safe mode is not available when the Docker backend is in use.

### File System Isolation (Default)

| Path / Resource | Access | Notes |
| ---------------- | ------ | ----- |
| Current project directory | Read/write | Primary working tree (plus any paths passed with `--add-dir`) |
| `~/.claude` | Read/write | Session state, MCP configs, logs |
| Detected config directory (`$XDG_CONFIG_HOME/claude` or `~/.claude`) | Read/write | Needed for new Claude CLI defaults |
| `~/.claude.json` | Read/write | CLI top-level state file |
| `~/.ssh` | Read-only | Exposed so git can use host keys; consider using ssh-agent instead |
| `~/.gitconfig` | Read-only | Git identity and settings |
| Temporary credential file | Read-only | Mounted at runtime; becomes read/write only with `--allow-oauth-refresh` |
| macOS Keychain | No access | Becomes read/write with `--allow-keychain` (CRITICAL security risk) |
| Other host paths | No access | Unless explicitly mounted via flags |

**Safe Mode (`--safe`, native only, experimental)**
- **Provides stronger filesystem isolation**: Hides your entire `$HOME` directory from Claude, significantly reducing exposure of personal files, dotfiles, secrets, and caches.
- **macOS behavior**: Uses Seatbelt policies to deny reads under `$HOME`.
- **Linux behavior**: Uses bubblewrap tmpfs overlay to replace `$HOME` with an empty directory.
- **Still allows**: Access to project directory and paths explicitly shared via `--add-dir` or `--allow-readonly`.
- **Compatibility warning**: May cause tools to fail if they need config files in `$HOME`. Use `--allow-readonly ~/.tool-config` to selectively expose needed paths.
- **Docker limitation**: Safe mode only applies to native sandboxing (Seatbelt/bubblewrap). Docker mode provides inherent isolation by only mounting explicitly specified paths.

**Custom Rules**
- Use `--allow-readonly PATH` to share specific files/directories read-only without granting write access.
- Use `--deny-path PATH` to hide a path entirely (appears empty/blocked inside the sandbox). In Docker/bubblewrap this is implemented with empty overlays; in Seatbelt it raises access errors.
- `--add-dir PATH[:ro|:rw]` lets you control permissions inline when mounting additional content.
- Git worktree support auto-detects `git rev-parse --git-common-dir` only for trusted git layouts. Use `--disable-git-worktree-common-dir` if you want fully manual control and no auto-added git paths.

## Terminal Injection Attacks (Linux)

### The Vulnerability

On Linux, sandboxed processes can potentially escape containment through terminal injection attacks using the TIOCSTI and TIOCLINUX ioctls:

**TIOCSTI (CVE-2017-5226)**: This ioctl allows a process to inject characters into the terminal's input queue, effectively "typing" keystrokes. A sandboxed process sharing a controlling terminal with its parent can inject commands that execute in the parent shell after the sandbox exits.

**TIOCLINUX (CVE-2023-1523)**: Similar to TIOCSTI, this ioctl can inject input on Linux virtual consoles, providing another vector for terminal-based sandbox escape.

### How `cco` Mitigates This

The bubblewrap sandbox on Linux uses seccomp filtering to block these dangerous ioctls:

- **Pre-compiled BPF filters**: Ships with architecture-specific seccomp filters for x86_64 and aarch64 that block TIOCSTI and TIOCLINUX
- **Automatic fallback**: On other architectures, compiles the filter from source on first run (requires only a C compiler, no libraries)
- **Security hardening**: Filters include 32-bit command masking to prevent bypass attempts, x32 ABI rejection on x86_64, and architecture validation

When these ioctls are blocked, any attempt to use them returns EPERM (Operation not permitted) instead of succeeding.

### Why Not Use `--new-session`?

Bubblewrap's `--new-session` flag would also prevent TIOCSTI attacks by detaching the sandbox from the controlling terminal. However, this breaks interactive terminal functionality that Claude Code requires (prompts, terminal resizing, job control). The seccomp approach blocks only the dangerous ioctls while preserving full TTY interactivity.

### Verification

You can verify the protection is working:

```bash
# Inside the sandbox, TIOCSTI should be blocked
./sandbox -- python3 -c "import fcntl; fcntl.ioctl(0, 0x5412, b'x')"
# Should fail with: OSError: [Errno 1] Operation not permitted
```

### Limitations

- **macOS**: The Seatbelt sandbox on macOS does not require this mitigation as it uses a different security model
- **Docker mode**: Docker containers have their own isolation and don't share a controlling terminal with the host in the same way

## Experimental Features Security Considerations

⚠️ **The following features are optional and may introduce additional security risks:**

### Host Docker Socket (`--docker-socket`)
**Purpose**: Mount the host's Docker socket so Claude can build/run containers from inside `cco`.

**Security Implications**:
- **Host escape**: Access to `/var/run/docker.sock` effectively grants root-equivalent control over the host (Claude can start privileged containers, mount arbitrary paths, etc.).
- **Audit difficulty**: Actions run inside Docker may be less visible to the user.

**Recommendation**: Avoid this flag unless you fully trust the workload and require nested Docker access. Use a separate, constrained Docker context if possible.

### Codex Compatibility Mode (`--codex-mode`)
**Purpose**: Improve Codex compatibility in Docker by forcing nested Codex invocations to rely on `cco` as the outer sandbox.

When enabled (Docker backend only), `cco`:
- Prepends a `codex` PATH shim inside the container that forces nested `codex` calls to use `--dangerously-bypass-approvals-and-sandbox` and strips nested sandbox-mode flags.

**Security Implications**:
- **Nested Codex sandbox bypass**: Nested `codex` commands no longer use Codex's own Linux sandbox, and instead rely on the outer `cco` sandbox boundary.
- **PATH interception**: `--codex-mode` intentionally intercepts `codex` command resolution inside the container; debugging command behavior may be less obvious unless users know the shim is active.

**Recommendation**:
- Use `--codex-mode` only when needed for Codex compatibility issues in Docker.
- Do not combine it with other high-risk flags (for example `--privileged` or broad host mounts) unless you explicitly accept near-unsandboxed behavior.
- Prefer native backend or default Docker settings when compatibility allows.
- Treat this as a compatibility override mode, not a general default for all sessions.

**Risk Assessment**: **MEDIUM** - This mode disables nested Codex sandboxing and intercepts `codex` via PATH precedence. It does not add Docker privilege-expanding flags and still relies on `cco` for containment.

### OAuth Token Refresh (`--allow-oauth-refresh`)
**Purpose**: Allows Claude to refresh expired OAuth tokens and sync them back to the host system.

**Security Implications**:
- **Credential write access**: Claude gains ability to modify authentication credentials
- **Race condition risk**: Multiple `cco` instances could corrupt credentials
- **Sync-back attacks**: Malicious content could potentially manipulate token refresh to corrupt host credentials
- **Increased attack surface**: More complex credential handling creates more failure modes

**Mitigation**:
- Creates automatic timestamped backups before any credential updates
- Uses content comparison to detect concurrent modifications
- Preserves container credentials for manual recovery if sync-back fails
- Only enables when explicitly requested via `--allow-oauth-refresh`

### Keychain Access (`--allow-keychain`)
**Purpose**: Allows Claude to access macOS Keychain for OAuth token refresh in seatbelt sandbox mode.

**Security Implications**: **CRITICAL RISK**
- **Complete Keychain access**: Grants Claude read/write access to your ENTIRE Keychain
- **Password exposure**: Claude can access ALL stored passwords, certificates, and credentials
- **Credential theft**: Can extract passwords for websites, SSH keys, encryption certificates, etc.
- **Keychain manipulation**: Can add, modify, or delete any Keychain entry
- **System-wide compromise**: Keychain often contains credentials for email, iCloud, Wi-Fi, corporate systems, etc.

**What Claude can do with Keychain access**:
- `security dump-keychain` - Export ALL passwords and certificates
- `security find-generic-password -a <any-app>` - Access any application's credentials
- `security find-internet-password` - Access all stored web passwords
- `security add-generic-password` - Add malicious credentials
- `security delete-generic-password` - Remove existing credentials

**Mitigation**:
- **Disabled by default**: Keychain access is blocked unless explicitly enabled
- **Explicit opt-in required**: Users must actively choose `--allow-keychain` flag
- **Clear warnings**: Help text and documentation emphasize the extreme danger
- **Recommendation**: Create a separate Keychain specifically for Claude Code
- **Alternative**: Accept token expiration and restart `cco` when needed (secure default)

**Risk Assessment**: **CRITICAL** - This flag effectively defeats Keychain isolation. Only enable if you fully understand and accept the risk of exposing ALL your stored credentials to Claude.

### Credential Management (`backup-creds`, `restore-creds`)
**Purpose**: Manual backup and restoration of Claude Code credentials.

**Security Implications**:
- **Credential exposure**: Backup files contain sensitive authentication data
- **File system security**: Backup security depends on host filesystem permissions
- **Restore accidents**: Incorrect restoration could corrupt authentication

**Mitigation**:
- Backup files created with restrictive permissions (600)
- Pre-restore backups created automatically before restoration
- User confirmation required for automatic restoration from most recent backup
- Cross-platform support (macOS Keychain + Linux files) with appropriate security handling

### Sandbox Backend Passthrough (`--`)
**Purpose**: Pass arbitrary arguments directly to the underlying sandbox backend (Docker, bwrap, or sandbox-exec) for advanced configuration like port forwarding.

**Security Implications**:
- **User-controlled only**: These arguments come from the command line or `CCO_SANDBOX_ARGS_FILE`, not from Claude. Claude cannot inject sandbox arguments.
- **Potential to weaken isolation**: Users can pass flags that reduce security:
  - Docker: `--privileged`, `--cap-add`, `-v /:/host`, `--security-opt`, etc.
  - bwrap: `--bind` to mount additional paths, `--cap-add`, etc.
  - sandbox-exec: `-D` variables that might affect policy evaluation
- **File-based config risk**: If an attacker has write access to `CCO_SANDBOX_ARGS_FILE`, they could inject malicious sandbox arguments.

**Examples of dangerous passthrough args**:
```bash
# These defeat the sandbox - DON'T DO THIS
cco -- --privileged                    # Full host access
cco -- -v /:/hostroot                  # Mount entire host filesystem
cco -- --cap-add=ALL                   # All capabilities
cco -- --security-opt=seccomp=unconfined  # Disable seccomp
```

**Safe usage** (intended use cases):
```bash
# Port forwarding for development servers
cco -- -p 3000:3000

# Custom networking
cco -- --network=mynetwork

# Environment variables
cco -- -e DEBUG=1
```

**Mitigation**:
- Arguments after `--` require explicit user action; Claude cannot trigger them
- Document dangerous patterns clearly
- Users should understand Docker/bwrap/sandbox-exec security before using advanced flags
- Protect `CCO_SANDBOX_ARGS_FILE` with appropriate filesystem permissions

**Risk Assessment**: **Low** for normal use (port forwarding, env vars). **HIGH** if misused with privileged flags. This feature trusts the user to understand what they're passing to the sandbox backend.

### External Git Common Dir Override (`--allow-external-git-dir`)
**Purpose**: Allow `cco` to mount a git common dir even when git metadata indicates a non-standard layout.

**Security Implications**:
- **Wider writable scope**: Can grant write access to a `.git` directory outside the normal worktree/main-repo structure.
- **Trust assumption**: You are explicitly trusting local git metadata and repository setup.

**Mitigation**:
- Disabled by default; only trusted layouts are auto-allowed.
- Explicit opt-in required via `--allow-external-git-dir` (or `CCO_ALLOW_EXTERNAL_GIT_DIR=1`).
- Use `--disable-git-worktree-common-dir` for strict manual mounts only.

**Risk Assessment**: **Medium** when enabled on untrusted or unknown local repos. **Low** in trusted single-user workflows.

### Recommendation
These experimental features are disabled by default. Only enable them if you understand the additional security implications and have implemented appropriate safeguards (regular backups, monitoring, etc.).

## Risk Assessment

### High Risk Scenarios (Mitigated by `cco`)
- **Malicious web content instructs Claude to modify host system files**: Changes stay inside the sandboxed filesystem.
- **Claude attempts to install persistent host software**: Package installs and service writes affect only the container/sandbox environment.

### Medium Risk Scenarios (Partially Mitigated)
- **Claude modifies project source code maliciously**: Still possible; limited to project and whitelisted paths.
- **Prompt injection causes internal network probing**: Possible because network access is unrestricted—rely on network segmentation and service auth.
- **Sensitive project data exfiltrated via API**: Limited to data Claude can read (project + mounted paths).

### Low Risk Scenarios (Not Mitigated)
- **Claude displays misleading information**: User vigilance required
- **Resource exhaustion within container**: System resource limits should be configured

## Best Practices

### For General Use
1. **Review changes**: Always inspect code modifications before committing
2. **Limit sensitive data**: Don't store credentials in project directories
3. **Use version control**: Track all changes to detect unauthorized modifications
4. **Regular updates**: Keep `cco` updated with latest security improvements

### For Sensitive Projects
1. **Isolated environment**: Use dedicated machines for highly sensitive work
2. **Network monitoring**: Monitor container network activity
3. **File integrity**: Use file integrity monitoring on project directories
4. **Backup verification**: Regularly verify backup integrity

### For Organizations
1. **Docker security**: Configure Docker daemon with appropriate security policies
2. **Network policies**: Implement network segmentation for container traffic
3. **Monitoring**: Deploy container runtime security monitoring
4. **Incident response**: Establish procedures for container security incidents

## Limitations and Assumptions

`cco`'s security model assumes:

1. **Container technology works**: Docker provides effective isolation
2. **Host system security**: Host is not already compromised
3. **User vigilance**: Users review changes before committing
4. **Network security**: Appropriate network controls are in place
5. **Regular updates**: Security patches are applied promptly

## Incident Response

### If you suspect Claude has been compromised by malicious content:

1. **Immediate containment**:
   - Stop the cco container: `docker stop <container-name>`
   - Do not commit any recent changes
   
2. **Assessment**:
   - Review recent file modifications in project directory
   - Check git history for unexpected commits
   - Examine container logs: `docker logs <container-name>`

3. **Recovery**:
   - Rebuild cco image: `cco --rebuild`
   - Restore project files from known-good backup if necessary
   - Re-authenticate Claude Code: `claude logout && claude`

## Conclusion

cco should be more secure than running Claude Code directly on your host system. Container isolation helps contain some of the nastier scenarios like host filesystem access and privilege escalation.

But "more secure" doesn't mean "secure" - there are still plenty of ways things can go wrong. The main remaining risk is compromise of your project directory itself, which you should mitigate through version control, backups, and reviewing changes.

For most use cases, cco should be a reasonable improvement over raw Claude Code. But I'm not a security expert - this is just my understanding of how containers work. Do your own evaluation. If you need actual security guarantees, you'll need more than a Docker container. If you want a more convenient Claude Code experience while reducing your odds of getting `rm -rf /`-ed, then cco might be a good fit.
