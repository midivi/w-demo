ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=28.1.1
ARG DEBIAN_VERSION=trixie-20260713-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/library/debian:${DEBIAN_VERSION}"

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
COPY assets assets
COPY config/runtime.exs config/

RUN mix compile --warnings-as-errors
RUN mix assets.deploy
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
ENV PORT=8080

WORKDIR /app
RUN chown nobody:root /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/wail ./

USER nobody

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/wail", "start"]
