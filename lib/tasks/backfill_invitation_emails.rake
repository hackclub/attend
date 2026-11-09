namespace :backfill do
  # Invitations follow a participant's email change since
  # Invitation.follow_email_change! was added. This repairs the ones left
  # behind before then: an unaccepted invitation whose address no participant
  # has any more, where paper_trail shows a participant moving off that
  # address. Prints ids only, so the output is safe to paste anywhere.
  desc "Move unaccepted invitations off addresses participants have left (dry run unless APPLY=1)"
  task invitation_emails: :environment do
    apply = ENV["APPLY"] == "1"
    moved = 0
    untraced = 0

    orphaned = Invitation.where(accepted_at: nil)
      .where("NOT EXISTS (SELECT 1 FROM participants WHERE LOWER(participants.email) = LOWER(invitations.email))")

    orphaned.distinct.pluck(Arel.sql("LOWER(invitations.email)")).each do |address|
      participant_id = PaperTrail::Version
        .where(item_type: "Participant", event: "update")
        .where("object_changes ILIKE ?", "%#{Invitation.sanitize_sql_like(address)}%")
        .order(created_at: :desc)
        .find { |version| version.changeset["email"]&.first.to_s.downcase == address }
        &.item_id
      participant = participant_id && Participant.find_by(id: participant_id)

      ids = orphaned.for_email(address).pluck(:id)
      unless participant
        untraced += ids.size
        next
      end

      moved += ids.size
      puts "invitations #{ids.join(", ")} -> participant #{participant.id}"
      Invitation.follow_email_change!(from: address, to: participant.email) if apply
    end

    puts "\n#{apply ? "Moved" : "Would move"} #{moved} invitation(s); left #{untraced} with no recorded email change alone."
    puts "Dry run — re-run with APPLY=1 to write changes." unless apply
  end
end
