# syntax=docker/dockerfile:1
# check=error=true

ARG RUBY_VERSION=4.0.2
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /app

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl \
      libjemalloc2 \
      sqlite3 \
      tini && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development test" \
    RACK_ENV=production \
    RUBY_YJIT_ENABLE=1

# ---- gems stage ----
FROM base AS gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libyaml-dev \
      pkg-config \
      libsqlite3-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf \
      ~/.bundle/ \
      "${BUNDLE_PATH}"/ruby/*/cache \
      "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# ---- assets stage: Tailwind v4 via the standalone CLI, no Node.js ----
FROM base AS assets
ARG TAILWIND_VERSION=v4.1.14
ARG TARGETARCH=amd64
RUN curl -sSL -o /usr/local/bin/tailwindcss \
      "https://github.com/tailwindlabs/tailwindcss/releases/download/${TAILWIND_VERSION}/tailwindcss-linux-${TARGETARCH}" && \
    chmod +x /usr/local/bin/tailwindcss
COPY app ./app
RUN mkdir -p app/assets/built && \
    tailwindcss \
      -i app/assets/tailwind.css \
      -o app/assets/built/application.css \
      --minify

# ---- final runtime ----
FROM base
COPY --from=gems "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY . .
COPY --from=assets /app/app/assets/built ./app/assets/built

RUN set -eux; \
    groupadd --system app; \
    useradd --system --gid app --create-home --shell /bin/bash app; \
    mkdir -p /app/state /app/log; \
    chown -R app:app /app/state /app/log

USER app:app

EXPOSE 4567
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS "http://localhost:${PORT:-4567}/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/start"]
