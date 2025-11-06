#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
	echo -e "${GREEN}▶${NC} $1"
}

warn() {
	echo -e "${YELLOW}⚠${NC} $1"
}

error() {
	echo -e "${RED}✗${NC} $1" >&2
}

info() {
	echo -e "${BLUE}ℹ${NC} $1"
}

# Configuration
GITHUB_REPO="nikvdp/cco"
GITHUB_SSH_URL="git@github.com:${GITHUB_REPO}.git"
GITHUB_HTTPS_URL="https://github.com/${GITHUB_REPO}.git"
CCO_INSTALLATION_DIR="$HOME/.local/share/cco"

# Determine symlink location using smart strategy
determine_symlink_location() {
	# Smart symlink strategy: use ~/bin if user already has it in PATH
	if [[ -d "$HOME/bin" && ":$PATH:" == *":$HOME/bin:"* ]]; then
		SYMLINK_DIR="$HOME/bin"
		NEEDS_SUDO=false
		log "Using existing ~/bin directory"
	else
		# Use system location, requires sudo
		SYMLINK_DIR="/usr/local/bin"
		NEEDS_SUDO=true
		log "Using /usr/local/bin (requires sudo)"
	fi

	SYMLINK_PATH="${SYMLINK_DIR}/cco"
}

# Check sandbox backend availability
check_sandbox_availability() {
	local os
	os="$(uname -s)"
	local available_backends=()
	local missing_suggestions=()
	local warnings=()

	if [[ "$os" == "Darwin" ]]; then
		# macOS: Check for sandbox-exec (Seatbelt)
		if command -v sandbox-exec &>/dev/null; then
			available_backends+=("native sandbox (Seatbelt)")
		else
			missing_suggestions+=("sandbox-exec (should be built-in on macOS)")
		fi
	elif [[ "$os" == "Linux" ]]; then
		# Linux: Check for bubblewrap
		if command -v bwrap &>/dev/null; then
			available_backends+=("native sandbox (bubblewrap)")
		else
			missing_suggestions+=("bubblewrap: apt install bubblewrap / dnf install bubblewrap / pacman -S bubblewrap")
		fi
	else
		warn "Unsupported OS: $os - only Docker backend will be available"
	fi

	# Check for Docker (fallback backend)
	if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
		available_backends+=("Docker")
	elif command -v docker &>/dev/null; then
		warnings+=("Docker is installed but daemon is not running")
		missing_suggestions+=("Docker: start Docker daemon or install from https://docs.docker.com/get-docker/")
	else
		missing_suggestions+=("Docker: https://docs.docker.com/get-docker/")
	fi

	# Show warnings first
	for warning_msg in "${warnings[@]}"; do
		warn "$warning_msg"
	done

	if [[ ${#available_backends[@]} -eq 0 ]]; then
		warn "No sandbox backend currently available for cco"
		warn ""
		warn "cco requires at least one of the following sandbox backends to run:"
		for suggestion in "${missing_suggestions[@]}"; do
			warn "  • $suggestion"
		done
		warn ""
		warn "Note: Native sandboxing is preferred for performance, Docker is used as fallback"
		warn ""
		warn "Installation will continue, but cco will not work until a sandbox backend is installed."
		return 0
	fi

	# Show what's available
	if [[ ${#available_backends[@]} -eq 1 ]]; then
		log "Sandbox backend available: ${available_backends[0]}"
	else
		log "Sandbox backends available: $(
			IFS=', '
			echo "${available_backends[*]}"
		)"
	fi

	# Show suggestions for missing backends (informational, not blocking)
	if [[ ${#missing_suggestions[@]} -gt 0 ]]; then
		info "Additional sandbox options can be installed:"
		for suggestion in "${missing_suggestions[@]}"; do
			info "  • $suggestion"
		done
	fi
}

# Check prerequisites
check_prerequisites() {
	log "Checking prerequisites..."

	# Check for required tools
	local missing_tools=()

	if ! command -v git &>/dev/null; then
		missing_tools+=("git")
	fi

	if [[ ${#missing_tools[@]} -gt 0 ]]; then
		error "Missing required tools: ${missing_tools[*]}"
		error "Please install them and try again."
		exit 1
	fi

	# Check for sandbox backends
	check_sandbox_availability

	log "Prerequisites check passed"
}

# Clone with SSH first, fallback to HTTPS
clone_repository() {
	local target_dir="$1"

	log "Attempting to clone with SSH authentication..."
	if git clone "$GITHUB_SSH_URL" "$target_dir" 2>/dev/null; then
		log "Successfully cloned using SSH"
		return 0
	fi

	warn "SSH clone failed, falling back to HTTPS..."
	if git clone "$GITHUB_HTTPS_URL" "$target_dir"; then
		log "Successfully cloned using HTTPS"
		return 0
	fi

	error "Failed to clone repository with both SSH and HTTPS"
	return 1
}

# Clone or update cco installation
install_or_update_cco() {
	# Determine if we're in a cco repo
	if [[ -f "cco" && -f "Dockerfile" ]]; then
		log "Running from cco development directory"
	else
		log "Running standalone installation"
	fi

	# Clone/update cco installation
	if [[ -d "$CCO_INSTALLATION_DIR/.git" ]]; then
		log "Updating existing cco installation..."
		cd "$CCO_INSTALLATION_DIR"

		# Check for local modifications
		if ! git diff --quiet HEAD 2>/dev/null; then
			warn "WARNING: Your cco installation has local modifications."
			warn "Most users should reset to the latest version (this is safe)."
			warn "Only say 'no' if you've customized cco yourself."
			echo
			read -p "Reset to latest version and lose local changes? [Y/n] " -n 1 -r
			echo
			if [[ $REPLY =~ ^[Nn]$ ]]; then
				warn "Skipping update to preserve local changes"
				cd - >/dev/null
				return 0
			fi
			log "Resetting to latest version..."
			git reset --hard origin/master
		fi

		git fetch origin
		git pull origin master
		CURRENT_VERSION=$(git rev-parse --short HEAD)
		log "Updated to $CURRENT_VERSION"
		cd - >/dev/null
	else
		log "Installing cco to $CCO_INSTALLATION_DIR..."
		mkdir -p "$(dirname "$CCO_INSTALLATION_DIR")"

		if ! clone_repository "$CCO_INSTALLATION_DIR"; then
			error "Failed to clone cco repository"
			error "Please check your internet connection and try again."
			exit 1
		fi

		CURRENT_VERSION=$(cd "$CCO_INSTALLATION_DIR" && git rev-parse --short HEAD)
		log "Installed cco $CURRENT_VERSION"
	fi
}

# Create symlink
create_symlink() {
	log "Creating symlink..."

	# Create symlink with appropriate permissions
	if [[ "$NEEDS_SUDO" == "true" ]]; then
		if ! sudo ln -sf "$CCO_INSTALLATION_DIR/cco" "$SYMLINK_PATH"; then
			error "Failed to create symlink with sudo"
			exit 1
		fi
		log "Created symlink at $SYMLINK_PATH (used sudo)"
	else
		if ! ln -sf "$CCO_INSTALLATION_DIR/cco" "$SYMLINK_PATH"; then
			error "Failed to create symlink"
			exit 1
		fi
		log "Created symlink at $SYMLINK_PATH"
	fi
}

# Verify installation
verify_installation() {
	log "Verifying installation..."

	if [[ ! -x "$CCO_INSTALLATION_DIR/cco" ]]; then
		error "Installation verification failed: cco script is not executable"
		exit 1
	fi

	if [[ ! -L "$SYMLINK_PATH" ]]; then
		error "Installation verification failed: symlink was not created"
		exit 1
	fi

	# Try to run cco --help
	if ! "$SYMLINK_PATH" --help &>/dev/null; then
		error "Installation verification failed: cco --help failed"
		exit 1
	fi

	log "Installation verified successfully"
}

# Show usage information
show_usage() {
	info ""
	info "🎉 cco installation complete!"
	info ""
	info "📍 Installation details:"
	info "  • Files: ${BLUE}$CCO_INSTALLATION_DIR${NC}"
	info "  • Command: ${BLUE}$SYMLINK_PATH${NC}"
	info "  • Version: ${BLUE}$CURRENT_VERSION${NC}"
	info ""
	info "📋 Next steps:"
	info "  1. Make sure Claude Code is authenticated"
	info "  2. Run cco in any project directory: ${BLUE}cco${NC}"
	info "  3. For help: ${BLUE}cco --help${NC}"
	info "  4. To update: ${BLUE}cco self-update${NC}"
	info ""
	info "📖 Documentation: https://github.com/${GITHUB_REPO}"
	info ""
}

# Main installation function
main() {
	log "🚀 Installing cco - a thin protective layer for Claude Code"
	echo

	check_prerequisites
	determine_symlink_location
	install_or_update_cco
	create_symlink
	verify_installation
	show_usage
}

# Handle command line arguments
case "${1:-}" in
	--help | -h)
		echo "cco installer - a thin protective layer for Claude Code"
		echo ""
		echo "Usage: curl -fsSL https://raw.githubusercontent.com/nikvdp/cco/master/install.sh | bash"
		echo ""
		echo "This script will:"
		echo "  • Clone cco to ~/.local/share/cco"
		echo "  • Create symlink in ~/bin (if in PATH) or /usr/local/bin"
		echo "  • Enable global cco usage from any directory"
		echo ""
		echo "Options:"
		echo "  --help, -h    Show this help message"
		exit 0
		;;
	*)
		main
		;;
esac
