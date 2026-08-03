# Find eligible builder and runner images on Docker Hub. Debian is used for
# both stages so the release and compiled NIFs keep the same runtime ABI.
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=28.1.1
ARG NODE_VERSION=26.4.0
ARG DEBIAN_VERSION=trixie-20260713-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG NODE_IMAGE="docker.io/library/node:${NODE_VERSION}-trixie-slim"
ARG RUNNER_IMAGE="docker.io/library/debian:${DEBIAN_VERSION}"

FROM ${NODE_IMAGE} AS node_dependencies

WORKDIR /app

COPY assets/package.json assets/package-lock.json ./assets/
RUN npm --prefix assets ci

FROM ${NODE_IMAGE} AS node_runtime_dependencies

WORKDIR /app

COPY assets/package.json assets/package-lock.json ./assets/
RUN npm --prefix assets ci --omit=dev --omit=optional

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV=prod
ENV ERL_AFLAGS="+JMsingle true"

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile
RUN mix assets.setup

COPY priv priv
COPY lib lib
RUN mix compile --warnings-as-errors

COPY assets assets
COPY --from=node_dependencies /app/assets/node_modules assets/node_modules
RUN mix assets.deploy

# Runtime configuration is copied after compilation so deployment-only
# configuration changes do not invalidate the preceding build layers.
COPY config/runtime.exs config/
RUN mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    libatomic1 \
    libncurses6 \
    libstdc++6 \
    locales \
    openssl \
    tini \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV MIX_ENV=prod
ENV HOME=/app
ENV PHX_SERVER=true

# PDF generation is a runtime responsibility, so retain only the Node binary,
# production npm dependencies, and renderer sources.
COPY --from=node_dependencies /usr/local/bin/node /usr/local/bin/node

WORKDIR /app
RUN chown nobody:root /app

COPY --from=node_runtime_dependencies --chown=nobody:root /app/assets/package.json /app/assets/package-lock.json ./assets/
COPY --from=node_runtime_dependencies --chown=nobody:root /app/assets/node_modules ./assets/node_modules
COPY --from=builder --chown=nobody:root /app/priv/pdf ./priv/pdf

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/wid ./

USER nobody

EXPOSE 4000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/wid", "start"]
