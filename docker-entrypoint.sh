#!/bin/sh
set -e

# Get host UID/GID from environment
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# If already running as the target user, just exec
if [ "$(id -u)" = "$HOST_UID" ]; then
	exec "$@"
fi

# Running as root, need to set up user
echo "▶ Setting up container user with UID:GID ${HOST_UID}:${HOST_GID}..."

# Create group if needed
if ! getent group "$HOST_GID" >/dev/null 2>&1; then
	groupadd -g "$HOST_GID" hostgroup
fi

# Handle user creation/modification
if ! id -u "$HOST_UID" >/dev/null 2>&1; then
	# Create new user (suppress UID range warning for macOS UIDs)
	UID_MIN=100 UID_MAX=65000 useradd -u "$HOST_UID" -g "$HOST_GID" -d /home/hostuser -s /bin/bash -m hostuser 2>/dev/null || useradd -u "$HOST_UID" -g "$HOST_GID" -d /home/hostuser -s /bin/bash -m hostuser
	# Add to sudo group with passwordless sudo
	usermod -a -G sudo hostuser 2>/dev/null || true
	USER_NAME="hostuser"
	USER_HOME="/home/hostuser"
else
	# User already exists
	USER_NAME=$(id -nu "$HOST_UID")
	USER_HOME=$(getent passwd "$HOST_UID" | cut -d: -f6)
	# Add to sudo group with passwordless sudo
	usermod -a -G sudo "$USER_NAME" 2>/dev/null || true
fi

# Configure passwordless sudo for the user
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/$USER_NAME"
chmod 440 "/etc/sudoers.d/$USER_NAME"

# Ensure home directory exists and has correct ownership (for all cases)
mkdir -p "$USER_HOME" 2>/dev/null || true
chown "$HOST_UID:$HOST_GID" "$USER_HOME" 2>/dev/null || true

# Create and fix ownership of common cache/config directories
mkdir -p "$USER_HOME/.cache" "$USER_HOME/.config" "$USER_HOME/.local" 2>/dev/null || true
chown -R "$HOST_UID:$HOST_GID" "$USER_HOME/.cache" "$USER_HOME/.config" "$USER_HOME/.local" 2>/dev/null || true

# Fix ownership of mounted claude files (but don't recurse deeply on mounted volumes)
if [ -f "$USER_HOME/.claude.json" ]; then
	chown "$HOST_UID:$HOST_GID" "$USER_HOME/.claude.json" 2>/dev/null || true
fi

# Switch to the target user and run the command
# Build the command string properly, ensuring HOME is set correctly
cmd=""
for arg in "$@"; do
	# Escape single quotes in the argument
	escaped_arg=$(printf '%s\n' "$arg" | sed "s/'/'\\\\''/g")
	cmd="$cmd '$escaped_arg'"
done

# Set HOME environment variable and run command (preserve working directory)
exec su -s /bin/sh "$USER_NAME" -c "export HOME='$USER_HOME' && $cmd"
