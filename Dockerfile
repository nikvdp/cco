FROM debian:bookworm

# Install Node.js via NodeSource repository and all system dependencies in one layer
RUN apt-get update && apt-get install -y curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    # Node.js from NodeSource
    nodejs \
    # Core development tools
    build-essential git wget vim nano \
    # Modern shell tools
    jq ripgrep fzf fd-find bat htop tmux shellcheck \
    # Languages and runtimes
    python3 python3-pip python3-venv \
    golang-go \
    # Database clients (minimal set)
    postgresql-client sqlite3 \
    # Network and system tools
    netcat-openbsd telnet dnsutils iputils-ping \
    # Media processing
    ffmpeg \
    # Container tools
    docker.io \
    # System administration
    sudo procps \
    # Misc utilities
    tree less file unzip zip \
    # Environment management
    direnv \
    && rm -rf /var/lib/apt/lists/* \
    && echo 'eval "$(direnv hook bash)"' >> /etc/bash.bashrc

# Set Rust environment variables (before installation for better caching)
ENV CARGO_HOME=/opt/cargo \
    RUSTUP_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:$PATH

# Install Rust using rustup (official Rust installer)
# Using a specific toolchain version for better cache predictability
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal \
    && chmod -R a+rx /opt/cargo/bin

# Install packages not available in Debian repos
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Python environment management tool)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv \
    && mv /root/.local/bin/uvx /usr/local/bin/uvx

# Install JavaScript/TypeScript development tools
RUN npm install -g \
    ts-node \
    tsx \
    yarn \
    pnpm

# Install bun (JavaScript runtime)
RUN curl -fsSL https://bun.sh/install | bash \
    && mv /root/.bun/bin/bun /usr/local/bin/bun

# Install mise (polyglot runtime manager)
RUN curl https://mise.run | sh \
    && mv /root/.local/bin/mise /usr/local/bin/mise

# Install shfmt (shell formatter) - non-blocking, build continues even if this fails
RUN ARCH=$(case $(uname -m) in \
        x86_64) echo amd64;; \
        aarch64) echo arm64;; \
        armv7l) echo arm;; \
        *) echo amd64;; \
    esac) \
    && SHFMT_FALLBACK_VERSION="v3.12.0" \
    && echo "Attempting to install shfmt..." \
    && SHFMT_VERSION=$(curl -s https://api.github.com/repos/mvdan/sh/releases/latest | jq -r .tag_name 2>/dev/null) \
    && if [ -z "$SHFMT_VERSION" ] || [ "$SHFMT_VERSION" = "null" ]; then \
        echo "Failed to fetch latest version, using fallback: $SHFMT_FALLBACK_VERSION"; \
        SHFMT_VERSION="$SHFMT_FALLBACK_VERSION"; \
    else \
        echo "Using latest version: $SHFMT_VERSION"; \
    fi \
    && echo "Downloading shfmt ${SHFMT_VERSION} for architecture: $ARCH" \
    && SHFMT_URL="https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}/shfmt_${SHFMT_VERSION}_linux_${ARCH}" \
    && echo "URL: $SHFMT_URL" \
    && if curl -fsSL "$SHFMT_URL" -o /usr/local/bin/shfmt 2>/dev/null; then \
        chmod +x /usr/local/bin/shfmt \
        && echo "shfmt installed successfully: $(/usr/local/bin/shfmt --version)" \
        || echo "shfmt installed but version check failed"; \
    else \
        echo "Warning: Failed to download shfmt, continuing without it"; \
    fi

# Create symlinks for fd (some systems call it fdfind)
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# Install custom packages if specified
ARG CUSTOM_PACKAGES=""
RUN if [ -n "$CUSTOM_PACKAGES" ]; then \
        apt-get update && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y $CUSTOM_PACKAGES && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Install Claude Code via official native installer (no longer npm)
ARG CACHE_BUST=default
RUN echo "Cache bust: ${CACHE_BUST}" && \
    curl -fsSL https://claude.ai/install.sh | bash

# Install other CLI coding agents via npm (always fetch latest versions)
RUN npm install -g \
    @openai/codex@latest \
    opencode-ai@latest \
    @factory/cli@latest \
    @google/gemini-cli@latest \
    @mariozechner/pi-coding-agent@latest

# Don't set a default user - let the entrypoint handle user creation and setup
# The entrypoint will create the appropriate user and set HOME correctly

# Don't set hardcoded environment variables - let entrypoint handle this
# Claude configuration will be mounted at runtime - no baking into image
# cco provides secure, thin-wrapper containerization for Claude Code

# Set entrypoint for user management
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# Default command: Run Claude Code
CMD ["claude", "--dangerously-skip-permissions"]