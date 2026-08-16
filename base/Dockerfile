FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV NVM_DIR=/root/.nvm

WORKDIR /root

# -----------------------------
# Essential tools
# -----------------------------
RUN apt update && apt upgrade -y && apt install -y --no-install-recommends \
    apt-transport-https \
    bash \
    ca-certificates \
    curl \
    dnsutils \
    git \
    gnupg \
    software-properties-common \
    htop \
    iproute2 \
    iputils-ping \
    jq \
    lsb-release \
    nano \
    net-tools \
    nmap \
    pipx \
    python3 \
    python3-pip \
    python3-venv \
    openssh-client \
    sudo \
    tcpdump \
    telnet \
    traceroute \
    unzip \
    vim \
    wget

# -----------------------------
# Python
# -----------------------------
RUN add-apt-repository ppa:deadsnakes/ppa -y && apt update && apt install -y python3.14

# -----------------------------
# Node.JS and npm
# -----------------------------
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash \
    && export NVM_DIR="$NVM_DIR" \
    && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" \
    && [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion" \
    && nvm install --lts \
    && NODE_VERSION="$(nvm current)" \
    && ln -sf "$NVM_DIR/versions/node/$NODE_VERSION/bin/node" /usr/local/bin/node \
    && ln -sf "$NVM_DIR/versions/node/$NODE_VERSION/bin/npm" /usr/local/bin/npm \
    && ln -sf "$NVM_DIR/versions/node/$NODE_VERSION/bin/npx" /usr/local/bin/npx

# -----------------------------
# Golang
# -----------------------------
RUN curl -fsSL https://go.dev/dl/go1.21.5.linux-amd64.tar.gz | tar -C /usr/local -xzvf -
ENV PATH="/usr/local/go/bin:${PATH}"

# -----------------------------
# Java
# -----------------------------
RUN apt install -y openjdk-21-jdk

# -----------------------------
# Git
# -----------------------------
RUN add-apt-repository ppa:git-core/ppa -y && apt update && apt upgrade -y git

# -----------------------------
# Pre commit
# -----------------------------
RUN pipx ensurepath && pipx install pre-commit \
    && go install github.com/lietu/go-pre-commit@v0.1.0
ENV PATH="/root/.local/bin:/root/go/bin:/usr/local/go/bin:${PATH}"

# -----------------------------
# Docker CLI
# -----------------------------
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
     && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
         > /etc/apt/sources.list.d/docker.list \
     && apt update && apt install -y docker-ce-cli docker-ce containerd.io docker-ce-rootless-extras uidmap

# -----------------------------
# Rootless Docker daemon account
# -----------------------------
# Rootless dockerd refuses to start as root, so a dedicated non-root account
# exists solely to satisfy that requirement (it is a run-as-user workaround,
# not a privilege-separation boundary — see the plan's Key Technical
# Decisions). Ubuntu's useradd already auto-assigns a subuid/subgid range on
# user creation, but we drop that implicit range and pin an explicit,
# documented one instead so the size is guaranteed regardless of distro
# defaults. daemon.json intentionally leaves "storage-driver" unset: rootless
# dockerd auto-selects overlay2 if the kernel supports unprivileged overlay
# mounts, falling back to fuse-overlayfs and only using vfs as a last
# resort — that default order already satisfies "prefer overlay-family, not
# vfs" without hardcoding a single driver that could fail to start on hosts
# whose kernel only supports one of the two.
RUN useradd --create-home --shell /bin/bash dockerd \
    && sed -i '/^dockerd:/d' /etc/subuid /etc/subgid \
    && usermod --add-subuids 100000-165535 --add-subgids 100000-165535 dockerd \
    && mkdir -p /home/dockerd/.config/docker \
    && printf '{}\n' > /home/dockerd/.config/docker/daemon.json \
    && chown -R dockerd:dockerd /home/dockerd/.config

# -----------------------------
# Terraform CLI
# -----------------------------
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
       > /etc/apt/sources.list.d/hashicorp.list \
    && apt update && apt install -y terraform
RUN curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash

# -----------------------------
# Google Cloud SDK
# -----------------------------
RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" \
       > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt update && apt install -y google-cloud-cli

# -----------------------------
# AWS CLI
# -----------------------------
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" && \
    unzip /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip

# -----------------------------
# Ansible
# -----------------------------
RUN pipx install ansible-core ansible-lint

# -----------------------------
# kubectl (Kubernetes client)
# -----------------------------
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && rm kubectl

# -----------------------------
# MongoDB Shell (mongosh)
# -----------------------------
RUN curl -fsSL https://pgp.mongodb.com/server-6.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-6.0.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/mongodb-server-6.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" \
        | tee /etc/apt/sources.list.d/mongodb-org-6.0.list \
    && apt update && apt install -y mongodb-mongosh

# -----------------------------
# PostgreSQL client (psql)
# -----------------------------
RUN apt install -y postgresql-client

# -----------------------------
# Act (GitHub Actions runner)
# -----------------------------
RUN curl -fsSL https://raw.githubusercontent.com/nektos/act/master/install.sh | bash \
    && mv ./bin/act /usr/local/bin/act \
    && rm -rf /root/bin

# -----------------------------
# GitHub CLI
# -----------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt update && apt install -y gh

# -----------------------------
# BitBucket CLI
# -----------------------------
RUN wget https://github.com/bb-cli/bb-cli/releases/download/1.4.1/bb \
    && mv bb /usr/local/bin/bb \
    && chmod +x /usr/local/bin/bb \
    && apt install php-cli php-curl php-mbstring -y

# -----------------------------
# SonarQube Scanner CLI
# -----------------------------
RUN curl -fsSL https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-8.1.0.6389-linux-x64.zip -o /tmp/sonar-scanner-cli.zip \
    && unzip -q /tmp/sonar-scanner-cli.zip -d /opt \
    && mv /opt/sonar-scanner-* /opt/sonar-scanner \
    && ln -s /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner \
    && rm /tmp/sonar-scanner-cli.zip

# -----------------------------
# GitHub Copilot CLI
# -----------------------------
RUN curl -fsSL https://gh.io/copilot-install | bash

# -----------------------------
# Claude CLI
# -----------------------------
RUN curl -fsSL https://claude.ai/install.sh | bash

# -----------------------------
# opencode CLI
# -----------------------------
# The opencode installer always places the binary at ~/.opencode/bin (no env
# var override exists) and otherwise relies on editing shell rc files to add
# that directory to PATH - which has no effect in a non-interactive RUN. Link
# it into /root/.local/bin instead, the same already-on-PATH directory the
# Claude CLI installer uses.
RUN curl -fsSL https://opencode.ai/install | bash \
    && ln -s /root/.opencode/bin/opencode /root/.local/bin/opencode

# -----------------------------
# Supervisor (for the rootless Docker daemon)
# -----------------------------
# Installs and configures supervisor to run dockerd-rootless.sh as the
# dockerd account, but does not launch supervisord itself here -
# entrypoint.sh decides whether to start it, gated by setup.json's
# docker.enabled opt-in (see a later implementation unit). No new apt
# repo is needed: supervisor is in Ubuntu 24.04's universe repo, already
# reachable from the apt update at the top of this file. Ubuntu's
# supervisor package ships a default /etc/supervisor/supervisord.conf
# that already includes every *.conf file under /etc/supervisor/conf.d/,
# so supervisord.conf here is a conf.d fragment containing only the
# [program:dockerd] stanza, not a full supervisord config.
RUN apt install -y supervisor \
    && mkdir -p /var/log/supervisor \
    && chown dockerd:dockerd /var/log/supervisor
COPY supervisord.conf /etc/supervisor/conf.d/dockerd.conf

# -----------------------------
# Clean up
# -----------------------------
RUN apt clean && rm -rf /var/lib/apt/lists/*

# -----------------------------
# Entrypoint
# -----------------------------
COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# -----------------------------
# Default command
# -----------------------------
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["sleep", "infinity"]
