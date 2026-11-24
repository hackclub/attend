namespace :checkin_codes do
  # Prints a new P-256 private key for signing check-in QR codes. Add it to
  # credentials under ticket_signing.keys with the next free id (1-255):
  #
  #   ticket_signing:
  #     keys:
  #       1: |
  #         -----BEGIN EC PRIVATE KEY-----
  #         ...
  #
  # The highest id signs new codes; keep older ids listed until every ticket
  # signed with them is out of use, or scanners will turn those tickets away.
  desc "Print a new private key for signing check-in QR codes"
  task generate_key: :environment do
    puts CheckinCode.generate_key.to_pem
  end

  # Wallet passes only pick up the signed code when something prompts an
  # update. This asks for one on every pass for events that haven't ended, so
  # phones get the new code before the door. Passes whose contents didn't
  # change are skipped by WalletPassUpdateService. Dry run unless APPLY=1.
  desc "Push wallet pass updates so passes for upcoming events carry the signed code"
  task refresh_wallet_passes: :environment do
    abort "No ticket_signing keys configured; passes would keep the unsigned code." unless CheckinCode.signing_enabled?

    upcoming = ParticipantEvent.where(event_id: Event.not_ended.select(:id)).select(:id)
    ids = Passkit::Pass.where(generator_type: "ParticipantEvent", generator_id: upcoming).distinct.pluck(:generator_id)

    if ENV["APPLY"] == "1"
      ids.each { |id| WalletPassUpdateJob.perform_later(id) }
      puts "Queued wallet pass updates for #{ids.size} registrations."
    else
      puts "#{ids.size} registrations have wallet passes for events that haven't ended. Run with APPLY=1 to push updates."
    end
  end
end
