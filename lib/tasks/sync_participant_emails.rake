namespace :backfill do
  desc "Sync participants.email to the linked user's current email (dry run unless APPLY=1)"
  task participant_emails: :environment do
    apply = ENV["APPLY"] == "1"
    count = 0

    Participant.joins(:user)
      .where("participants.email IS DISTINCT FROM users.email")
      .where.not(users: { email: [ nil, "" ] })
      .includes(:user)
      .find_each do |participant|
        count += 1
        puts "#{participant.id}: #{participant.email} -> #{participant.user.email}"
        next unless apply

        # Skip validations: pre-existing invalid data on the participant
        # (e.g. a legacy phone number) must not block the email sync.
        participant.email = participant.user.email
        participant.save!(validate: false)
      end

    puts "\n#{apply ? "Updated" : "Would update"} #{count} participant(s)."
    puts "Dry run — re-run with APPLY=1 to write changes." unless apply
  end
end
