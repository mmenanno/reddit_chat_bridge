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

# ---- assets stage: Tailwind v4 + DaisyUI via npm ----
# DaisyUI is a JS plugin and has to be require()'able for Tailwind's @plugin
# directive to resolve. Node lives only in this stage — the runtime image
# never sees it. Only the compiled CSS is copied into the final stage.
FROM base AS assets
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y nodejs npm && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY app ./app
RUN npm init -y >/dev/null && \
    npm install --silent --no-save tailwindcss@^4 @tailwindcss/cli@^4 daisyui@^5 && \
    mkdir -p app/assets/built && \
    npx @tailwindcss/cli \
      -i app/assets/tailwind.css \
      -o app/assets/built/application.css \
      --minify

# ---- final runtime ----
FROM base
COPY --from=gems "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY . .
COPY --from=assets /app/app/assets/built ./app/assets/built

RUN set -eux; \
    groupadd --gid 1000 app; \
    useradd --uid 1000 --gid app --create-home --shell /bin/bash app; \
    mkdir -p /app/state /app/log; \
    chown -R 1000:1000 /app/state /app/log

USER 1000:1000

EXPOSE 4567
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS "http://localhost:${PORT:-4567}/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/start"]
