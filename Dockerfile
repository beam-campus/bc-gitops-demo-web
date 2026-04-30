# Dockerfile for bc-gitops-demo-web
# Multi-stage build for Elixir Phoenix release with bc_gitops
#
# Build: docker build -t demo-web:latest .
# Run:   docker run -e RELEASE_NODE=demo@localhost -e RELEASE_COOKIE=macula_dev demo-web:latest

ARG ELIXIR_VERSION=1.17
ARG DEBIAN_VERSION=bookworm-slim

ARG BUILDER_IMAGE="elixir:${ELIXIR_VERSION}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# =============================================================================
# Build Stage
# =============================================================================
FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
# cmake and ninja-build are required for quicer (QUIC NIF)
RUN apt-get update -y && apt-get install -y \
    build-essential \
    git \
    curl \
    cmake \
    ninja-build \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set build environment
ENV MIX_ENV=prod

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy bc_gitops dependency (copied into build context by build script)
# Note: mix.exs references {:bc_gitops, path: "../bc-gitops"}
# so we need to place it at ../bc-gitops relative to /app
COPY bc-gitops /bc-gitops

# Copy macula dependency (copied into build context by build script)
# Note: mix.exs references {:macula, path: "../../macula-io/macula"}
# so we need to place it at the expected relative path from /app
COPY macula /macula-io/macula

# Copy application files
COPY mix.exs mix.lock ./
COPY config config

# Fetch dependencies
RUN mix deps.get --only $MIX_ENV

# Compile dependencies
RUN mix deps.compile

# Copy application code
COPY lib lib
COPY priv priv
COPY assets assets

# Compile application first (generates colocated hooks)
RUN mix compile

# Compile assets (needs compiled app for phoenix-colocated)
RUN mix assets.deploy

# Copy runtime config
COPY config/runtime.exs config/

# Build release
COPY rel rel
RUN mix release

# =============================================================================
# Runner Stage
# =============================================================================
FROM ${RUNNER_IMAGE}

# Install runtime dependencies
RUN apt-get update -y && apt-get install -y \
    libstdc++6 \
    openssl \
    libncurses5 \
    locales \
    ca-certificates \
    curl \
    iproute2 \
    git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Create non-root user
RUN groupadd --gid 1000 app && \
    useradd --uid 1000 --gid app --shell /bin/bash --create-home app

# Create macula directories with proper permissions for TLS cert generation
# Macula auto-generates self-signed certs in development mode
RUN mkdir -p /var/lib/macula && \
    chown app:app /var/lib/macula && \
    chmod 755 /var/lib/macula

# Copy release from builder
COPY --from=builder --chown=app:app /app/_build/prod/rel/demo_web ./

USER app

# Erlang distribution ports
# 4369 = EPMD
# 9100-9105 = Distribution ports (one per node in cluster)
EXPOSE 4000 4369 9100 9101 9102 9103 9104 9105

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:${PORT:-4000}/health || exit 1

# Default command - use the start script from rel/overlays
CMD ["bin/start"]
