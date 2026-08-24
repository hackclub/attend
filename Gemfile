source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.6"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"

# yay logging!
gem "appsignal"

# Distributed tracing
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"
gem "opentelemetry-instrumentation-all"

# Authentication
gem "devise"
gem "omniauth"
gem "omniauth-oauth2"
gem "omniauth-rails_csrf_protection"

# Authorization
gem "pundit"

# MCP server — Rails-native (toolboxes are controllers, tools are actions)
gem "toolchest", "~> 0.3.7"
# mcp 0.23.0 is the first release with fixes for the five 2026 transport
# advisories (unbounded request body, SSE session poisoning, DNS rebinding,
# unbounded stdio line buffer, unbounded session retention). toolchest 0.3.x
# still targets the 0.11 signatures, so config/initializers/toolchest_mcp_compat.rb
# bridges the two — read it before bumping either gem.
gem "mcp", "~> 0.23.0"
gem "jb" # JSON view layer for toolbox actions

# Audit logging
gem "paper_trail"

# SQL query tool
gem "blazer"

# Console auditing - TEMPORARILY DISABLED
# gem "console1984"
# gem "audits1984"

# HTTP client for external APIs
gem "faraday"
gem "faraday-follow_redirects"
gem "faraday-retry"

# Transactional email via Postmark
gem "postmark-rails"

# Phone number validation and formatting
gem "phonelib"

# Twilio for SMS and WhatsApp
gem "twilio-ruby"

# Rate limiting
gem "rack-attack"

# Error monitoring
gem "sentry-ruby"
gem "sentry-rails"

# QR code generation
gem "rqrcode"

# Apple Wallet passes
gem "passkit", "~> 0.6"
gem "apnotic" # APNS HTTP/2 for push notifications to Apple Wallet

# Google Wallet passes
gem "google_wallet"

# PDF generation
gem "prawn"
gem "prawn-table"

# PDF parsing — validating uploaded template PDFs and photo-upload scans
gem "pdf-reader"

# Markdown processing
gem "kramdown"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.21"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Job monitoring dashboard
gem "mission_control-jobs"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.0", ">= 2.0.1"
gem "mini_magick"
gem "ruby-vips"

# S3-compatible storage (Cloudflare R2)
gem "aws-sdk-s3", require: false

gem "dotenv-rails", groups: [ :development, :test ]

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Testing
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "faker"
  gem "webmock"
  gem "vcr"
  gem "capybara"
  gem "selenium-webdriver"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Preview emails in browser via web UI
  gem "letter_opener_web"
end

gem "flipper", "~> 1.4"
gem "flipper-active_record", "~> 1.4"
