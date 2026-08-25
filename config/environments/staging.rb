require "active_support/core_ext/integer/time"

# Staging exists so a bug shows up here before it shows up on
# attend.hackclub.com, which only works if staging behaves like production. So
# we load production's config verbatim and override only what must differ: the
# public host, the storage bucket, and the outbound-integration guards.
#
# Everything genuinely secret comes from config/credentials/staging.yml.enc
# (unlocked by the RAILS_MASTER_KEY set on the staging deployment), so staging
# talks to staging Postmark/Twilio/Airtable/Slack accounts, not production's.
load Rails.root.join("config/environments/production.rb")

Rails.application.configure do
  # The staging deployment's public host. production.rb already allows any
  # *.hackclub.com host, so this only matters for a *.k.hackclub.dev ingress.
  staging_host = ENV.fetch("APP_HOST", "staging.attend.hackclub.com")

  config.action_mailer.default_url_options = { host: staging_host, protocol: "https" }
  # staging_host covers the public ingress. The other two are how the cluster
  # itself reaches the app: kubelet probes and in-cluster traffic arrive with the
  # service's internal name, and Orchard also serves an auto-generated
  # *.k.hackclub.dev ingress alongside the real hostname. Without them those
  # requests are rejected by host authorization.
  config.hosts |= [ staging_host, ".svc.cluster.local", ".k.hackclub.dev" ]

  # Staging uploads must not land in production's R2 bucket.
  config.active_storage.service = :cloudflare_r2_staging

  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "debug")

  # Emails are rewritten to STAGING_MAIL_RECIPIENT, or dropped if it is unset.
  # See config/initializers/staging_mail_interceptor.rb — that guard is what
  # stops a staging box from mailing real guardians.
  config.action_mailer.raise_delivery_errors = false
end
