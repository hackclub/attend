class BackfillUserOwnedNfcTokens < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      INSERT INTO nfc_tokens
        (id, token, user_id, paired_at, paired_by_id, created_at, updated_at)
      SELECT
        gen_random_uuid(),
        participant_events.nfc_badge_token,
        participants.user_id,
        participant_events.nfc_badge_assigned_at,
        participant_events.nfc_badge_assigned_by_id,
        COALESCE(participant_events.created_at, NOW()),
        NOW()
      FROM participant_events
      INNER JOIN participants ON participants.id = participant_events.participant_id
      WHERE participant_events.nfc_badge_token IS NOT NULL
        AND participant_events.nfc_badge_assigned_at IS NOT NULL
        AND participants.user_id IS NOT NULL
      ON CONFLICT (token) DO NOTHING
    SQL
  end

  def down
    # Legacy columns remain authoritative during rollout, so this backfill is
    # intentionally not reversed.
  end
end
