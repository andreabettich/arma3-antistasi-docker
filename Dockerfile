FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    STEAM_HOME=/home/steam \
    ARMA_DIR=/arma3 \
    ARMA_APPID=233780 \
    ANTISTASI_RELEASE=latest

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        tar \
        unzip \
        unrar-free \
        p7zip-full \
        lib32gcc-s1 \
        lib32stdc++6 \
        libcurl4 \
        libstdc++6 \
        libssl3 \
        libc6 \
        locales \
        tini \
 && locale-gen en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04 ships a default `ubuntu` user at UID 1000 — remove it so
# `steam` can take UID 1000 (matches common host UIDs for bind mounts).
RUN userdel -r ubuntu 2>/dev/null || true \
 && useradd -m -u 1000 -d ${STEAM_HOME} -s /bin/bash steam \
 && mkdir -p ${ARMA_DIR} ${STEAM_HOME}/steamcmd \
 && chown -R steam:steam ${ARMA_DIR} ${STEAM_HOME}

USER steam
WORKDIR ${STEAM_HOME}/steamcmd

RUN curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
        | tar -xzf -

WORKDIR ${ARMA_DIR}

COPY --chown=steam:steam server.cfg /defaults/server.cfg
COPY --chown=steam:steam entrypoint.sh /usr/local/bin/entrypoint.sh

# game / steam query / steam master / VON / battleye (UDP)
EXPOSE 2302/udp 2303/udp 2304/udp 2305/udp 2306/udp

VOLUME ["/arma3"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
