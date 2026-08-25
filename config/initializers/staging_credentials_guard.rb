# Rails falls back to config/credentials.yml.enc when there is no
# environment-specific credentials file. In staging that fallback is the worst
# possible outcome: the box would boot happily against production's Postmark,
# Twilio, Airtable and Slack accounts. Refuse to start instead.
if Rails.env.staging? && !Rails.root.join("config/credentials/staging.yml.enc").exist?
  raise <<~MESSAGE
    Missing config/credentials/staging.yml.enc.

    Without it Rails would fall back to config/credentials.yml.enc — production's
    secrets — and staging would start mailing and texting real people.

    Create it with:
      bin/rails credentials:edit --environment staging

    then set RAILS_MASTER_KEY on the staging deployment to the contents of
    config/credentials/staging.key.
  MESSAGE
end
