# syntax=docker/dockerfile:1
# check=skip=SecretsUsedInArgOrEnv

# This Dockerfile is designed for production, not development. Build'n'run by hand:
# docker build -t attend .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name attend attend

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.7
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

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
