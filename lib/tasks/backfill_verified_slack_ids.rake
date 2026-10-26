namespace :backfill do
  desc "Resync users.verified_slack_id from encrypted OIDC claims (idempotent)"
  task verified_slack_ids: :environment do
    result = BackfillVerifiedSlackIdsJob.perform_now
    puts "Done. Repaired: #{result[:repaired]}, Failed: #{result[:failed]}"
  end
end
