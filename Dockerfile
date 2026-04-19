# Run with
# docker build -t gastown:latest -f Dockerfile .
FROM docker/sandbox-templates:claude-code

ARG GO_VERSION=1.25.8

USER root

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    pkg-config \
    libzstd-dev \
    git \
    sqlite3 \
    tmux \
    curl \
    ripgrep \
    zsh \
    gh \
    netcat-openbsd \
    tini \
    vim \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Install gosu for clean privilege drop (root → agent) in entrypoint.
# sudo is not used: no_new_privileges:true in docker-compose blocks it.
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://github.com/tianon/gosu/releases/latest/download/gosu-${ARCH}" \
        -o /usr/local/bin/gosu && \
    chmod +x /usr/local/bin/gosu && \
    gosu nobody true

# Install Go from official tarball (apt golang-go is too old)
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" | tar -C /usr/local -xz
ENV PATH="/app/gastown:/usr/local/go/bin:/home/agent/go/bin:/home/agent/.local/bin:${PATH}"

# Install beads (bd) with CGO enabled for embedded Dolt support.
# The curl|bash installer downloads a pre-built binary without CGO;
# go install with CGO_ENABLED=1 builds an embedded-capable binary.
RUN CGO_ENABLED=1 go install github.com/gastownhall/beads/cmd/bd@latest && \
    mv /root/go/bin/bd /usr/local/bin/bd
# Install dolt (needed for identity setup and migrations even in embedded mode)
RUN curl -fsSL https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash

# Install fnm and bun to /usr/local so all users get them
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/bin --skip-shell
RUN curl -fsSL https://bun.sh/install | bash && \
    mv /root/.bun/bin/bun /usr/local/bin/bun

# Relocate Claude CLI out of /home/agent so the bind-mount doesn't shadow it
RUN cp "$(readlink -f /home/agent/.local/bin/claude)" /usr/local/bin/claude

# Install kubectl and helm for k3s cluster access
RUN ARCH=$(dpkg --print-architecture) && \
    K8S_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt) && \
    curl -fsSL "https://dl.k8s.io/release/${K8S_VER}/bin/linux/${ARCH}/kubectl" \
        -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Set up directories
RUN mkdir -p /app /gt /gt/.dolt-data && chown -R agent:agent /app /gt

# Environment setup for bash and zsh
RUN echo 'export PATH="/app/gastown:$PATH"' >> /etc/profile.d/gastown.sh && \
    echo 'export PATH="/app/gastown:$PATH"' >> /etc/zsh/zshenv
RUN echo 'export COLORTERM="truecolor"' >> /etc/profile.d/colorterm.sh && \
    echo 'export COLORTERM="truecolor"' >> /etc/zsh/zshenv
RUN echo 'export TERM="xterm-256color"' >> /etc/profile.d/term.sh && \
    echo 'export TERM="xterm-256color"' >> /etc/zsh/zshenv
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /etc/profile.d/local-bin.sh && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> /etc/zsh/zshenv

USER agent

COPY --chown=agent:agent go.mod go.sum /app/gastown/
RUN cd /app/gastown && go mod download

# Copy only Go source so non-Go file changes don't bust the build cache
COPY --chown=agent:agent Makefile /app/gastown/
COPY --chown=agent:agent cmd/ /app/gastown/cmd/
COPY --chown=agent:agent internal/ /app/gastown/internal/

RUN cd /app/gastown && make build

# Copy remaining files (entrypoints, configs, templates) — after build so
# changes here don't invalidate the expensive compile step above
COPY --chown=agent:agent . /app/gastown

# Entrypoints: root script handles CA cert install then drops to agent
USER root
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
COPY docker-entrypoint-agent.sh /app/docker-entrypoint-agent.sh
RUN chmod +x /app/docker-entrypoint.sh /app/docker-entrypoint-agent.sh

WORKDIR /gt

ENTRYPOINT ["tini", "--", "/app/docker-entrypoint.sh"]
CMD ["sleep", "infinity"]
