# devsys — all-inclusive Ubuntu dev container, runs as root.
# Everything (runtimes, CLIs, shell, services) is baked in.
# Single mount at /root = full persistence (topped up from /etc/skel/devsys
# on every boot).
#
# Required env at runtime (container refuses to start if either is missing):
#   HOSTNAME     system hostname AND tailnet hostname (single source of truth)
#   TS_AUTHKEY   tailscale auth key (tskey-auth-...)

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/root \
    NPM_CONFIG_PREFIX=/root/.npm-global \
    PNPM_HOME=/root/.local/share/pnpm \
    BUN_INSTALL=/root/.bun \
    MISE_DATA_DIR=/root/.local/share/mise \
    PATH=/root/.local/bin:/root/.local/share/mise/shims:/root/.bun/bin:/root/.npm-global/bin:/root/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /root

# ---- Base packages ---------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release \
      iptables iproute2 openssh-client \
      bash zsh git vim less \
      build-essential pkg-config \
      ripgrep fd-find bat fzf htop ncdu jq \
      unzip rsync iputils-ping net-tools dnsutils \
      direnv tmux \
      redis-server \
      postgresql-client \
      python3 python3-pip python3-venv \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && ln -sf /usr/bin/batcat /usr/local/bin/bat \
 && rm -rf /var/lib/apt/lists/*

# ---- Third-party apt repos: tailscale, eza, gh, charm (glow) ----------------
RUN mkdir -p /etc/apt/keyrings /usr/share/keyrings \
 && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
 && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
      -o /etc/apt/sources.list.d/tailscale.list \
 && curl -fsSL https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
      | gpg --dearmor -o /etc/apt/keyrings/gierens.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
      > /etc/apt/sources.list.d/gierens.list \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && curl -fsSL https://repo.charm.sh/apt/gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/charm.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
      > /etc/apt/sources.list.d/charm.list \
 && chmod go+r /usr/share/keyrings/*.gpg /etc/apt/keyrings/*.gpg \
 && apt-get update && apt-get install -y --no-install-recommends \
      tailscale eza gh glow \
 && rm -rf /var/lib/apt/lists/*

# ---- Starship, flyctl (system-wide), lazygit -------------------------------
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir /usr/local/bin \
 && HOME=/opt curl -fsSL https://fly.io/install.sh | FLYCTL_INSTALL=/opt/fly HOME=/opt sh \
 && ln -sf /opt/fly/bin/flyctl /usr/local/bin/flyctl \
 && ln -sf /opt/fly/bin/flyctl /usr/local/bin/fly \
 && rm -rf /opt/.fly \
 && ARCH=$(dpkg --print-architecture) \
 && case "$ARCH" in \
      arm64) LG_ARCH=arm64  ;; \
      amd64) LG_ARCH=x86_64 ;; \
      *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac \
 && LG_VERSION=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
      | grep -oP '"tag_name": "v\K[^"]+') \
 && curl -fsSL -o /tmp/lazygit.tgz \
      "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LG_VERSION}_Linux_${LG_ARCH}.tar.gz" \
 && tar -xzf /tmp/lazygit.tgz -C /tmp lazygit \
 && install /tmp/lazygit /usr/local/bin/lazygit \
 && rm -f /tmp/lazygit /tmp/lazygit.tgz

# ---- Runtimes + globals (all installed into /root) --------------------------
RUN curl -fsSL https://mise.run | sh \
 && /root/.local/bin/mise use --global --yes node@lts \
 && /root/.local/bin/mise use --global --yes python@3.12 \
 && /root/.local/bin/mise reshim \
 && mkdir -p "$NPM_CONFIG_PREFIX" "$PNPM_HOME/store" "$PNPM_HOME/global" \
 && npm install -g \
      pnpm \
      neonctl \
      @anthropic-ai/claude-code \
      @google/gemini-cli \
      @openai/codex \
      opencode-ai \
      obsidian-headless \
 && pnpm config set store-dir      "$PNPM_HOME/store" \
 && pnpm config set global-dir     "$PNPM_HOME/global" \
 && pnpm config set global-bin-dir "$PNPM_HOME" \
 && curl -fsSL https://bun.sh/install | bash

# ---- Shell config + work dir ----------------------------------------------
RUN mkdir -p /root/work \
 && cat > /root/.zshenv <<'ZSHENV'
typeset -U path PATH
path=(
  "$HOME/.local/bin"
  "$HOME/.local/share/mise/shims"
  "$HOME/.bun/bin"
  "$HOME/.npm-global/bin"
  "$HOME/.local/share/pnpm"
  $path
)
export PATH
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export PNPM_HOME="$HOME/.local/share/pnpm"
export BUN_INSTALL="$HOME/.bun"
export MISE_DATA_DIR="$HOME/.local/share/mise"
ZSHENV

RUN cat > /root/.zshrc <<'ZSHRC'
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE

eval "$(~/.local/bin/mise activate zsh 2>/dev/null || true)"
eval "$(direnv hook zsh 2>/dev/null || true)"
eval "$(starship init zsh 2>/dev/null || true)"

alias ls='eza --group-directories-first'
alias ll='eza -lah --group-directories-first --git'
alias tree='eza --tree'
alias cat='bat --paging=never'
alias lg='lazygit'

# AI CLI "yolo" aliases — flag-based auto-approve. Codex and Gemini accept
# these flags as root; Claude does not, so 'claude' stays un-aliased and
# relies on ~/.claude/settings.json instead.
alias codex='codex --dangerously-bypass-approvals-and-sandbox'
alias gemini='gemini --yolo'

cd ~/work 2>/dev/null || true
ZSHRC

# .zlogin runs AFTER .zshrc for login shells. Some terminal wrappers
# (e.g. OrbStack's UI shell) reset pwd after .zshrc but before the
# prompt, so put the cd here too as a belt-and-suspenders.
RUN echo 'cd ~/work 2>/dev/null || true' > /root/.zlogin

# Use zsh as root's login shell.
RUN chsh -s /bin/zsh root

# ── AI CLI auto-approve configs ───────────────────────────────────────────
# Each tool gets the fullest auto-approve we can set *persistently* without
# a CLI flag. For codex/gemini the CLI flag path is preferred (aliased in
# .zshrc below) since those flags don't refuse as root. Claude's flag
# DOES refuse as root, so we lean entirely on settings.json for it.

# Claude Code — full bypass. IS_SANDBOX=1 is Claude's documented signal
# for "this is an intentionally-isolated container, skip the root guard",
# which enables defaultMode "bypassPermissions" even as root.
# No allow-list needed, no prompts for anything.
RUN mkdir -p /root/.claude \
 && cat > /root/.claude/settings.json <<'JSON'
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "deny": []
  },
  "env": {
    "IS_SANDBOX": "1"
  }
}
JSON

# Codex CLI (OpenAI) — ~/.codex/config.toml: never prompt, full sandbox
# access. docs: https://developers.openai.com/codex/config-reference
RUN mkdir -p /root/.codex \
 && cat > /root/.codex/config.toml <<'TOML'
approval_policy = "never"
sandbox_mode    = "danger-full-access"
TOML

# Gemini CLI (Google) — ~/.gemini/settings.json: auto-approve edits.
# YOLO mode can only be enabled via --yolo flag (see alias below), not in
# config, per google-gemini/gemini-cli docs.
RUN mkdir -p /root/.gemini \
 && cat > /root/.gemini/settings.json <<'JSON'
{
  "general": {
    "defaultApprovalMode": "auto_edit"
  }
}
JSON

# ---- Snapshot populated /root into /etc/skel/devsys, then empty /root so
# the runtime mount (volume) can seed itself. `install` ensures an empty
# /root with correct perms after the move.
RUN mkdir -p /etc/skel \
 && mv /root /etc/skel/devsys \
 && install -d -m 700 /root

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# z — tmux session/window manager (arrow-key picker). System-wide so it
# survives the /root → /etc/skel/devsys move and is available immediately
# without seeding.
COPY z.sh /usr/local/bin/z
RUN chmod +x /usr/local/bin/z

RUN printf '\n  devsys — all-inclusive dev container\n  work dir: ~/work\n\n' > /etc/motd

# Default pwd for every new process in the container (docker exec, OrbStack
# UI terminal, fly ssh console, tailscale ssh). Shell-agnostic — survives
# OrbStack's injected zsh which ignores /root/.zshrc and /root/.zlogin by
# setting its own ZDOTDIR.
WORKDIR /root/work

EXPOSE 6379
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
