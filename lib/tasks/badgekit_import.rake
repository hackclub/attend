namespace :badgekit do
  # One-shot migration off badgekit, the standalone app that owned
  # badge.hackclub.com before Attend took over the redirects. Its schema is a
  # single `users` table of (slack_id, redirect_url) — no password, no join —
  # so all this does is copy the rows across and link the ones whose Slack ID
  # matches an Attend account.
  #
  #   BADGEKIT_DATABASE_URL=postgres://... rails badgekit:import          # dry run
  #   BADGEKIT_DATABASE_URL=postgres://... APPLY=1 rails badgekit:import
  desc "Import redirect links from the standalone badgekit database (dry run unless APPLY=1)"
  task import: :environment do
    database_url = ENV["BADGEKIT_DATABASE_URL"].presence
    abort "Set BADGEKIT_DATABASE_URL to badgekit's postgres connection string." if database_url.nil?

    apply = ENV["APPLY"] == "1"

    # Anonymous Active Record classes can't take a connection, hence the name.
    source = Class.new(ActiveRecord::Base) do
      def self.name = "BadgekitUser"
    end
    source.establish_connection(database_url)

    rows = source.connection.select_all(<<~SQL).to_a
      SELECT slack_id, redirect_url
      FROM users
      WHERE slack_id IS NOT NULL
        AND redirect_url IS NOT NULL
        AND redirect_url <> ''
    SQL

    attend_user_for = lambda do |slack_id|
      User.find_by(slack_user_id: slack_id) ||
        User.where("oidc_claims->>'slack_id' = ?", slack_id).first
    end

    imported = 0
    linked = 0
    skipped = []

    rows.each do |row|
      slack_id = row["slack_id"].to_s.strip.upcase
      url = row["redirect_url"]

      existing = BadgeRedirect.for_slack_id(slack_id)
      if existing&.url.present?
        # Someone already set this one in Attend. The newer value wins — never
        # overwrite a live link with the one we're migrating away from.
        skipped << "#{slack_id}: already set in Attend"
        next
      end

      badge_redirect = existing || BadgeRedirect.new(slack_id: slack_id)
      badge_redirect.url = url
      badge_redirect.user ||= attend_user_for.call(slack_id)

      unless badge_redirect.valid?
        skipped << "#{slack_id}: #{badge_redirect.errors.full_messages.to_sentence} (#{url})"
        next
      end

      imported += 1
      linked += 1 if badge_redirect.user
      puts "#{slack_id} -> #{badge_redirect.url}#{badge_redirect.user ? " (#{badge_redirect.user.email})" : " (no Attend account)"}"
      badge_redirect.save! if apply
    end

    puts "\n#{apply ? "Imported" : "Would import"} #{imported} of #{rows.size} redirect(s); #{linked} linked to an Attend account."
    if skipped.any?
      puts "\nSkipped #{skipped.size}:"
      skipped.each { |line| puts "  #{line}" }
    end
    puts "\nDry run — re-run with APPLY=1 to write changes." unless apply
  end
end
