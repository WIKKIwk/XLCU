# TITAN BRIDGE - Dockerfile (production)

FROM hexpm/elixir:1.16.2-erlang-26.2.5-debian-bookworm-20240513-slim AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir -p config

# Compile-time config must be present before dependency compilation.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

# Changes to runtime.exs don't require recompiling the code.
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

FROM debian:bookworm-slim AS app

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    HOME=/app

WORKDIR /app
RUN chown nobody:nogroup /app

COPY --from=builder --chown=nobody:nogroup /app/_build/prod/rel/titan_bridge ./

USER nobody
CMD ["bin/titan_bridge", "start"]
