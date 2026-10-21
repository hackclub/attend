namespace :backfill do
  desc "Fill ucat_cases (Airtable record links) and temp-ban expiries on existing UCAT bans by running the sync once"
  task ucat_ban_cases: :environment do
    unless Bans::UcatSync.api_key.present?
      abort "No UCAT Airtable key configured (UCAT_AIRTABLE_API_KEY); nothing to sync from."
    end

    missing_before = Ban.ucat.where("ucat_cases = '[]'::jsonb").count
    expiring_before = Ban.ucat.where.not(expires_at: nil).count
    puts "UCAT bans: #{Ban.ucat.count} total, #{missing_before} without case links, #{expiring_before} with an expiry."

    # The ordinary sync already rewrites changed attributes on every synced
    # ban, so one run fills both columns. Goes through the job so the run is
    # logged and newly imported bans get the upcoming-enrollments alert, same
    # as the nightly run. Not forced: the revoke safety limit still applies,
    # and a tripped limit means the base needs a look first.
    result = SyncUcatBansJob.perform_now(force: ENV["FORCE"] == "1")
    puts "Sync: #{result.to_h}"

    missing_after = Ban.ucat.where("ucat_cases = '[]'::jsonb").count
    expiring_after = Ban.ucat.where.not(expires_at: nil).count
    puts "Filled case links on #{missing_before - missing_after} ban(s); #{missing_after} still without (revoked by hand or no longer in the base)."
    puts "Temp-ban expiries: #{expiring_before} -> #{expiring_after}."
  end
end
