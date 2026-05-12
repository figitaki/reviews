# Multi-stage Dockerfile for building a Phoenix release of :reviews.
#
# Build stage: Elixir 1.18 / Erlang 27 on Debian Bookworm, with Node added for
# the React-island asset bundle (esbuild needs node only to install the binary;
# the actual JS deps live in assets/node_modules).
#
# Runtime stage: slim Debian with only the libs the BEAM release needs.
#
# Usage:
#   docker build -t reviews:latest .
#   docker run --rm -p 4000:4000 \
#     -e SECRET_KEY_BASE=... \
#     -e DATABASE_URL=ecto://user:pass@host/reviews \
#     -e PHX_HOST=reviews.example.com \
#     -e GITHUB_CLIENT_ID=... -e GITHUB_CLIENT_SECRET=... \
#     reviews:latest

ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250407-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Install build deps: git for git-sourced hex deps (heroicons), curl for nodesource,
# build-essential for any NIFs.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Prepare hex/rebar for the build user.
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Install mix deps first so they cache independently of source changes.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config: copy the config files the deps compile against.
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# Asset sources + npm deps for the React island. esbuild/tailwind binaries are
# fetched by the mix tasks during assets.deploy, so no separate `npm run build`.
COPY assets assets
RUN cd assets && npm ci --no-audit --no-fund

# Application source.
COPY priv priv
COPY lib lib

# Runtime config and release assembly. `assets.deploy` runs tailwind + esbuild +
# phx.digest.
COPY config/runtime.exs config/

RUN mix assets.deploy
RUN mix compile

# Optional release overlays (rel/) — copied if present so `mix release` picks
# them up, but the Dockerfile works without a rel/ directory.
COPY rel rel

RUN mix release

# ---- Runtime stage ----

FROM ${RUNNER_IMAGE} AS runtime

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        libstdc++6 \
        openssl \
        libncurses6 \
        locales \
        ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set the locale so the BEAM can boot cleanly.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app

# Run as a non-root user.
RUN groupadd --system --gid 1001 app \
    && useradd --system --uid 1001 --gid 1001 --create-home --home-dir /app --shell /bin/bash app \
    && chown app:app /app

USER app:app

COPY --from=builder --chown=app:app /app/_build/prod/rel/reviews ./

# Defaults; override at run time.
ENV PHX_SERVER=true \
    PORT=4000 \
    HOME=/app

EXPOSE 4000

CMD ["/app/bin/server"]
