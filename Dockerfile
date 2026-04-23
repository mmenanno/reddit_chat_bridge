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

COPY --link Gemfile Gemfile.lock ./
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

# Node deps: isolated in their own layer so it only invalidates when
# package.json / package-lock.json change. `npm ci` is both faster and
# deterministic vs. `npm install` (it respects the lockfile exactly
# and skips dependency resolution against the registry).
COPY --link package.json package-lock.json ./
RUN npm ci --silent

# App source + asset compile invalidates whenever app/ changes.
# Only application.css and grain.png are served at runtime. The loose
# icon.svg and icons/icon-*.png files in app/assets/ are dev-only
# branding source — not referenced by any view or by application.css.
COPY --link app ./app
RUN mkdir -p app/assets/built && \
    npx @tailwindcss/cli \
      -i app/assets/tailwind.css \
      -o app/assets/built/application.css \
      --minify && \
    cp app/assets/grain.png app/assets/built/grain.png

# ---- final runtime ----
FROM base
ARG BUILD_SHA=""
ARG BUILD_REF=""
ARG BUILD_VERSION=""
ENV BUILD_SHA=$BUILD_SHA \
    BUILD_REF=$BUILD_REF \
    BUILD_VERSION=$BUILD_VERSION

RUN set -eux; \
    groupadd --gid 1000 app; \
    useradd --uid 1000 --gid app --create-home --shell /bin/bash app; \
    mkdir -p /app/state /app/log; \
    chown -R 1000:1000 /app/state /app/log

COPY --link --from=gems "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --link --from=assets /app/app/assets/built ./app/assets/built
COPY --link . .

USER 1000:1000

EXPOSE 4567
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS "http://localhost:${PORT:-4567}/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/start"]
