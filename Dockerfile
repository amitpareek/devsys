# devsys — all-inclusive Ubuntu dev container
# Everything (runtimes, CLIs, shell, services) is baked in.
# Single mount at /home/dev = full persistence (seeded on first boot from /etc/skel/devsys).
#
# Required env at runtime (container refuses to start if either is missing):
#   HOSTNAME     system hostname AND tailnet hostname (single source of truth)
#   TS_AUTHKEY   tailscale auth key (tskey-auth-...)

FROM ubuntu:24.04

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    USERNAME=${USERNAME} \
    HOME=/home/${USERNAME} \
    NPM_CONFIG_PREFIX=/home/${USERNAME}/.npm-global \
    PNPM_HOME=/home/${USERNAME}/.local/share/pnpm \
    BUN_INSTALL=/home/${USERNAME}/.bun \
    MISE_DATA_DIR=/home/${USERNAME}/.local/share/mise \
    PATH=/home/${USERNAME}/.local/bin:/home/${USERNAME}/.local/share/mise/shims:/home/${USERNAME}/.bun/bin:/home/${USERNAME}/.npm-global/bin:/home/${USERNAME}/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---- Base packages, user, apt-installable tools ----------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release sudo \
      iptables iproute2 openssh-client \
      bash zsh git vim less \
      build-essential pkg-config \
      ripgrep fd-find bat fzf htop ncdu jq \
      unzip rsync iputils-ping net-tools dnsutils \
      direnv tmux \
      redis-server \
      python3 python3-pip python3-venv \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && (userdel -r ubuntu 2>/dev/null || true) \
    && groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/zsh ${USERNAME} \
    && usermod -aG sudo ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && chmod 0755 /home/${USERNAME} \
    && install -d -m 755 -o ${USERNAME} -g ${USERNAME} \
         /home/${USERNAME}/.cache \
         /home/${USERNAME}/.config \
         /home/${USERNAME}/.local \
         /home/${USERNAME}/.local/bin \
         /home/${USERNAME}/.local/share \
         /home/${USERNAME}/.local/state \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME} \
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

# ---- Starship, flyctl (system-wide), lazygit, obsidian-export --------------
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir /usr/local/bin \
 && curl -fsSL https://fly.io/install.sh | FLYCTL_INSTALL=/opt/fly sh \
 && ln -sf /opt/fly/bin/flyctl /usr/local/bin/flyctl \
 && ln -sf /opt/fly/bin/flyctl /usr/local/bin/fly \
 && ARCH=$(dpkg --print-architecture) \
 && case "$ARCH" in \
      arm64) LG_ARCH=arm64;  OE_ARCH=aarch64-unknown-linux-gnu ;; \
      amd64) LG_ARCH=x86_64; OE_ARCH=x86_64-unknown-linux-gnu  ;; \
      *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac \
 && LG_VERSION=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
      | grep -oP '"tag_name": "v\K[^"]+') \
 && curl -fsSL -o /tmp/lazygit.tgz \
      "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LG_VERSION}_Linux_${LG_ARCH}.tar.gz" \
 && tar -xzf /tmp/lazygit.tgz -C /tmp lazygit \
 && install /tmp/lazygit /usr/local/bin/lazygit \
 && rm -f /tmp/lazygit /tmp/lazygit.tgz \
 && OE_URL=$(curl -fsSL https://api.github.com/repos/zoni/obsidian-export/releases/latest \
      | grep -oE '"browser_download_url":[^,]*'"$OE_ARCH"'[^,]*\.tar\.xz"' \
      | head -n1 | cut -d'"' -f4) \
 && if [ -n "$OE_URL" ]; then \
      curl -fsSL -o /tmp/oe.tar.xz "$OE_URL" \
      && tar -xJf /tmp/oe.tar.xz -C /tmp \
      && install "$(find /tmp -maxdepth 2 -type f -name obsidian-export | head -n1)" /usr/local/bin/obsidian-export \
      && rm -rf /tmp/oe.tar.xz /tmp/obsidian-export-*; \
    fi

# ---- Per-user installs: mise, node, python, bun, pnpm, npm globals ---------
USER ${USERNAME}
WORKDIR /home/${USERNAME}

RUN curl -fsSL https://mise.run | sh \
 && ~/.local/bin/mise use --global --yes node@lts \
 && ~/.local/bin/mise use --global --yes python@3.12 \
 && ~/.local/bin/mise reshim \
 && export PATH="$HOME/.local/share/mise/shims:$NPM_CONFIG_PREFIX/bin:$PATH" \
 && mkdir -p "$NPM_CONFIG_PREFIX" \
 && npm install -g \
      pnpm \
      neonctl \
      @anthropic-ai/claude-code \
      @google/gemini-cli \
      @openai/codex \
      opencode-ai \
 && mkdir -p "$PNPM_HOME/store" "$PNPM_HOME/global" \
 && pnpm config set store-dir      "$PNPM_HOME/store" \
 && pnpm config set global-dir     "$PNPM_HOME/global" \
 && pnpm config set global-bin-dir "$PNPM_HOME" \
 && curl -fsSL https://bun.sh/install | bash

# ---- Shell config, work/vault dirs ----------------------------------------
RUN mkdir -p /home/${USERNAME}/work /home/${USERNAME}/vault \
 && cat > /home/${USERNAME}/.zshenv <<'ZSHENV'
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

RUN cat > /home/${USERNAME}/.zshrc <<'ZSHRC'
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
alias claude='claude --dangerously-skip-permissions'

cd ~/work 2>/dev/null || true
ZSHRC

# ---- Snapshot the populated home into /etc/skel/devsys, then empty /home/dev
# so the runtime mount (volume) can seed itself on first boot.
USER root
RUN mkdir -p /etc/skel \
 && mv /home/${USERNAME} /etc/skel/devsys \
 && mkdir -p /home/${USERNAME} \
 && chown ${USERNAME}:${USERNAME} /home/${USERNAME}

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Also give root a quick motd
RUN printf '\n  devsys — all-inclusive dev container\n  work dir: ~/work   vault (optional): ~/vault\n\n' > /etc/motd

EXPOSE 6379
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
