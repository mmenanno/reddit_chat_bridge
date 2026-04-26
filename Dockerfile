# syntax=docker/dockerfile:1
# check=error=true

ARG RUBY_VERSION=4.0.2
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /app

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl \
      gosu \
      libjemalloc2 \
      sqlite3 \
      tini

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development test" \
    RACK_ENV=production \
    RUBY_YJIT_ENABLE=1

# ---- gems stage ----
FROM base AS gems
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libyaml-dev \
      pkg-config \
      libsqlite3-dev

COPY --link Gemfile Gemfile.lock ./
# No --mount=type=cache here: with BUNDLE_PATH=/usr/local/bundle, the
# real download cache lives at ${BUNDLE_PATH}/ruby/*/cache (which we
# rm at the end), not at ~/.bundle/cache. Mounting /root/.bundle/cache
# would both miss the real cache AND collide with the `rm -rf ~/.bundle/`
# cleanup below ("Device or resource busy"). CI's existing type=gha
# layer cache already caches the whole gems stage when Gemfile.lock
# is unchanged, which is the dominant win here.
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
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y nodejs npm

# Node deps: isolated in their own layer so it only invalidates when
# package.json / package-lock.json change. `npm ci` is both faster and
# deterministic vs. `npm install` (it respects the lockfile exactly
# and skips dependency resolution against the registry).
COPY --link package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm ci --silent

# Bot-icon PNG ships first in its own layer. Only the 1024×1024 variant
# ships — it matches Discord's recommended bot-avatar dimensions and is
# the single size the /guide/bot-setup download link serves. The other
# sizes (128/256/512) stay as dev-only exports under app/assets/icons/.
# Keeping the COPY narrow also means the layer only invalidates when
# that specific file regenerates via bin/build-icons.
COPY --link app/assets/icons/icon-1024.png ./app/assets/icons/icon-1024.png
RUN mkdir -p app/assets/built/icons && \
    cp app/assets/icons/icon-1024.png app/assets/built/icons/icon-1024.png

# App source + Tailwind compile. Invalidates on any app/ edit.
# Runtime-served assets under app/assets/built (= PUBLIC_ROOT):
#   - application.css       — compiled Tailwind bundle (built below)
#   - grain.png             — film-grain overlay referenced by the CSS
#   - icons/icon-<size>.png — bot-icon downloads (staged in the layer above)
COPY --link app ./app
RUN npx @tailwindcss/cli \
      -i app/assets/tailwind.css \
      -o app/assets/built/application.css \
      --minify && \
    cp app/assets/grain.png app/assets/built/grain.png

# ---- source consolidation stage ----
# Stages every small runtime artifact so the final image picks them up
# in a single `COPY --from=source` layer. Without this stage, each file
# group (lib, app/views, db/migrate, bin/start, configs) shipped as its
# own layer; several were under 10 KB compressed, where per-layer
# overhead exceeds the file content. Listing directories explicitly
# (rather than `COPY . .`) still scopes the layer to runtime-read paths
# only and avoids re-shipping the 3 MB loose icon source.
FROM base AS source
COPY --link lib ./lib
COPY --link app/views ./app/views
COPY --link db/migrate ./db/migrate
COPY --link bin/start bin/init ./bin/
COPY --link config.ru Gemfile Gemfile.lock VERSION ./

# ---- final runtime ----
FROM base
ARG BUILD_SHA=""
ARG BUILD_REF=""
ARG BUILD_VERSION=""
ENV BUILD_SHA=$BUILD_SHA \
    BUILD_REF=$BUILD_REF \
    BUILD_VERSION=$BUILD_VERSION \
    LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 \
    MALLOC_CONF=background_thread:true,dirty_decay_ms:1000,muzzy_decay_ms:1000

COPY --link --from=gems "${BUNDLE_PATH}" "${BUNDLE_PATH}"

# Single layer for all the small runtime sources. See the `source` stage
# above for rationale. Comes BEFORE the asset layers so that view edits
# (which invalidate this layer AND application.css) leave the icon and
# grain layers cached.
COPY --link --from=source /app /app

# Staged-asset COPYs split per artifact so each lands in its own layer.
# Icons (3 MB, regenerated only by bin/build-icons) get their own layer,
# so pulls skip that layer whenever the icon file is byte-identical to
# the previously-published image. grain.png is a stable static asset.
# application.css regenerates on every view or CSS edit; keeping it
# distinct lets pulls skip the icon and grain layers when only CSS
# changes.
COPY --link --from=assets /app/app/assets/built/icons ./app/assets/built/icons
COPY --link --from=assets /app/app/assets/built/grain.png ./app/assets/built/grain.png
COPY --link --from=assets /app/app/assets/built/application.css ./app/assets/built/application.css

# User creation comes AFTER the COPYs. Rationale: this RUN's output is
# non-deterministic (useradd embeds today's date in /etc/shadow and sets
# mtime=now on /home/app/*), so the layer changes every build regardless
# of position. Putting it here keeps the ~3 KB layer at the tail of the
# manifest so downstream consumers (Unraid's pull UI in particular) don't
# re-fetch the large stable layers that follow in build order.
RUN set -eux; \
    groupadd --gid 1000 app; \
    useradd --uid 1000 --gid app --create-home --shell /bin/bash app; \
    mkdir -p /app/state /app/log; \
    chown -R 1000:1000 /app/state /app/log; \
    chmod +x /app/bin/init /app/bin/start

# Container starts as root so bin/init can adjust the `app` user's
# uid/gid to match PUID/PGID env vars (Unraid convention), chown the
# state directory, set umask, then drop privileges via gosu before
# exec'ing bin/start. Without PUID/PGID, defaults to 1000:1000 - same
# as the previous USER directive behavior.

EXPOSE 4567
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS "http://localhost:${PORT:-4567}/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/init"]
