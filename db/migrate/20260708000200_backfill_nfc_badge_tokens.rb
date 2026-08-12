class BackfillNfcBadgeTokens < ActiveRecord::Migration[8.1]
  def up
    # update_all deliberately skips callbacks: ensure_nfc_badge_token! used to
    # run per row inside API reads, and each update! enqueued a wallet-pass
    # refresh job. Backfilling in SQL avoids that job storm.
    execute <<~SQL
      UPDATE participant_events
      SET nfc_badge_token = gen_random_uuid()
      WHERE nfc_badge_token IS NULL
    SQL

    # New rows always get a token, so read paths never need to create one.
    change_column_default :participant_events, :nfc_badge_token, from: nil, to: -> { "gen_random_uuid()" }
  end

  def down
    change_column_default :participant_events, :nfc_badge_token, from: -> { "gen_random_uuid()" }, to: nil
  end
end
