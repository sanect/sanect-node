# sanect node image for Railway.
# Builds `sanectd` from our cosmos/evm fork (bech32 prefix snct, chain IDs
# 76287 testnet / 7628 mainnet), then runs it behind Caddy so a single
# Railway HTTP port exposes EVM-RPC + Cosmos-RPC + REST.

# ---------- build stage ----------
FROM golang:1.25-bookworm AS build
# Let Go fetch the exact toolchain pinned in go.mod if newer than the image.
ENV GOTOOLCHAIN=auto
# Pin to a specific cosmos/evm git ref for reproducibility; bump when upgrading.
ARG COSMOS_EVM_REF=v0.4.1
# Bake the EVM chain ID into the binary at build time. The runtime
# --evm.evm-chain-id flag doesn't reach every code path — discovered
# 2026-06-22 when mainnet eth_chainId still reported 76287 even though
# app.toml said 7628. Override at build for mainnet:
#   docker build --build-arg TARGET_EVM_CHAIN_ID=7628 ...
# (Railway: set in service Settings → Build → Build Args.)
ARG TARGET_EVM_CHAIN_ID=76287
WORKDIR /src

# Run our fork builder against the pinned upstream ref. The script clones,
# sed-patches bech32 prefix + default chain IDs, builds, and installs to OUT.
# OUT here points inside the build stage so the runtime stage can copy it.
COPY scripts/fork-cosmos-evm.sh /tmp/fork-cosmos-evm.sh
RUN chmod +x /tmp/fork-cosmos-evm.sh \
    && OUT=/usr/local/bin/sanectd \
       COSMOS_EVM_REF=${COSMOS_EVM_REF} \
       TARGET_EVM_CHAIN_ID=${TARGET_EVM_CHAIN_ID} \
       /tmp/fork-cosmos-evm.sh

# ---------- runtime stage ----------
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates jq curl debian-keyring debian-archive-keyring apt-transport-https gnupg \
        lz4 cron unzip util-linux \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update && apt-get install -y --no-install-recommends caddy \
    && rm -rf /var/lib/apt/lists/*

# rclone — install from the upstream static zip rather than the curl|bash script
# (which silently relies on unzip + assumes a writable /tmp layout). Pin to a
# stable version so reproducibility holds. amd64-only is fine since Railway's
# x86_64 builders are what we ship from.
ARG RCLONE_VERSION=v1.68.2
RUN cd /tmp \
    && curl -fsSL -o rclone.zip "https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-amd64.zip" \
    && unzip -q rclone.zip \
    && mv rclone-${RCLONE_VERSION}-linux-amd64/rclone /usr/local/bin/rclone \
    && chmod +x /usr/local/bin/rclone \
    && rm -rf rclone.zip rclone-${RCLONE_VERSION}-linux-amd64

COPY --from=build /usr/local/bin/sanectd /usr/local/bin/sanectd
COPY scripts/localnet.sh /app/scripts/localnet.sh
COPY scripts/snapshot-upload.sh /app/scripts/snapshot-upload.sh
COPY scripts/snapshot-download.sh /app/scripts/snapshot-download.sh
COPY docker/entrypoint.sh /app/entrypoint.sh
COPY docker/Caddyfile /app/Caddyfile
RUN chmod +x /app/scripts/localnet.sh /app/scripts/snapshot-upload.sh /app/scripts/snapshot-download.sh /app/entrypoint.sh \
    && ln -s /app/scripts/snapshot-upload.sh /usr/local/bin/sanect-snapshot-now \
    && ln -s /app/scripts/snapshot-download.sh /usr/local/bin/sanect-snapshot-pull

# Railway sets $PORT; Caddy binds it. Chain data lives on a mounted volume.
ENV HOMEDIR=/data/.sanectd
ENV NETWORK=testnet
ENV CHAIN_ID=sanect_76287-1
ENV EVM_CHAIN_ID=76287
ENV DENOM=asnct
ENV DISPLAY=snct
ENV MONIKER=sanect-node

ENTRYPOINT ["/app/entrypoint.sh"]
