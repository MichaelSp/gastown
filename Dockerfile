# Run with
# docker build -t gastown:latest -f Dockerfile .
FROM docker/sandbox-templates:claude-code

ARG GO_VERSION=1.25.8

USER root

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
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
ENV PATH="/app/gastown:/usr/local/go/bin:/home/agent/go/bin:${PATH}"

# Install beads (bd) and dolt
RUN curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
RUN curl -fsSL https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash

# Install fnm and bun to /usr/local so all users get them
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/bin --skip-shell
RUN curl -fsSL https://bun.sh/install | bash && \
    mv /root/.bun/bin/bun /usr/local/bin/bun

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
