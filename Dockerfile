# syntax=docker/dockerfile:1
# check=skip=SecretsUsedInArgOrEnv

# This Dockerfile is designed for production, not development. Build'n'run by hand:
# docker build -t attend .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name attend attend

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.7

# libvips decodes every uploaded photo through libheif when the bytes are
# HEIC/HEIF (an iPhone's default) or AVIF, and Debian trixie ships libheif
# 1.19.8 — vulnerable to GHSA-g89c-p67h-r497 (CVSS 9.8, fixed in 1.23.2). A
# crafted file with nested `iden`/`auxl` item references produces duplicate
# alpha planes, and the scaler then writes 16-bit samples into an 8-bit plane:
# an attacker-controlled heap overflow, demonstrated as RCE, reachable from a
# plain heif_decode_image() with no unusual API options. Uploads hit that
# decoder twice here — DecodableImageAttachment validates them on the way in,
# and ApplicationHelper#viewable_upload_path renders HEIC through a JPEG
# variant — and anyone holding a consent link can upload, so the fix has to be
# in the image.
#
# Only sid carries 1.23.2: there is no trixie-backports build, and the trixie
# security update (1.19.8-1+deb13u1) predates the advisory. So build it from
# source here. Once trixie-security ships >= 1.23.2, delete this stage and the
# swap below and go back to plain libheif1 from apt.
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS libheif

ARG LIBHEIF_VERSION=1.23.2
ARG LIBHEIF_SHA256=8bd5d41d19dc84536d118b04774709f244df6104ef66d623dad5fa4650143405

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential ca-certificates cmake curl pkg-config \
      libde265-dev libdav1d-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

WORKDIR /src
RUN curl -fsSL -o libheif.tar.gz "https://github.com/strukturag/libheif/releases/download/v${LIBHEIF_VERSION}/libheif-${LIBHEIF_VERSION}.tar.gz" && \
    echo "${LIBHEIF_SHA256}  libheif.tar.gz" | sha256sum -c - && \
    tar xzf libheif.tar.gz && \
    cmake -S "libheif-${LIBHEIF_VERSION}" -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_INSTALL_LIBDIR="lib/$(uname -m)-linux-gnu" \
      -DENABLE_PLUGIN_LOADING=OFF \
      -DBUILD_TESTING=OFF \
      -DWITH_EXAMPLES=OFF \
      -DWITH_LIBDE265=ON \
      -DWITH_DAV1D=ON \
      -DWITH_AOM_DECODER=OFF \
      -DWITH_AOM_ENCODER=OFF \
      -DWITH_X265=OFF \
      -DWITH_UNCOMPRESSED_CODEC=OFF && \
    cmake --build build -j"$(nproc)" && \
    DESTDIR=/out cmake --install build && \
    rm -rf /out/usr/include /out/usr/lib/*/pkgconfig /out/usr/lib/*/cmake /out/usr/lib/*/libheif.so

FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips libde265-0 libdav1d7 postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

RUN rm -rf /usr/lib/*/libheif.so.1.* /usr/lib/*/libheif
COPY --from=libheif /out/usr/lib/ /usr/lib/
RUN ldconfig

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock vendor ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Fallback revision for builds whose context has no .git directory
ARG GIT_REVISION=unknown
ENV GIT_REVISION=${GIT_REVISION}

# Copy application code
COPY . .

# Write git revision for debug footer, then drop .git so it never reaches the
# final image
RUN if [ -d .git ]; then git rev-parse HEAD > REVISION; else echo "${GIT_REVISION}" > REVISION; fi && \
    rm -rf .git

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY.
#
# RAILS_MASTER_KEY is dropped for this step rather than merely left unset: the
# platform injects a deployment's env vars into the build, so the staging
# deployment's build would otherwise try to decrypt config/credentials.yml.enc —
# production's file, because RAILS_ENV is production here — with staging's key
# and fail with ActiveSupport::MessageEncryptor::InvalidMessage. Loading the
# production environment reads credentials (mailer settings, config.hosts), and
# none of those values affect the compiled assets. With no key at all the reads
# return nil, which is what a local or CI build has always done.
RUN env -u RAILS_MASTER_KEY SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

ARG GIT_REVISION=unknown
ENV APP_REVISION=${GIT_REVISION}

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
