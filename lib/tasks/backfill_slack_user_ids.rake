namespace :backfill do
  desc "Backfill slack_user_id on participants from user OIDC claims"
  task slack_user_ids: :environment do
    updated = 0
    skipped = 0

    Participant.where(slack_user_id: [ nil, "" ]).find_each do |participant|
      user = participant.user
      slack_id = user&.oidc_claims&.dig("slack_id")

      if slack_id.present?
        participant.update_column(:slack_user_id, slack_id)
        updated += 1
        puts "Updated #{participant.email} with Slack ID: #{slack_id}"
      else
        skipped += 1
      end
    end

    puts "\nDone. Updated: #{updated}, Skipped (no Slack ID): #{skipped}"
  end
end
