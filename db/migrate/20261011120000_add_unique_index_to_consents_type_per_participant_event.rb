# Waiver and freedom waiver consents are one-per-participant-event, but nothing
# enforced it: two guardian portal requests landing together could both miss in
# find_or_create_by! and each create (and send) their own DocuSeal submission.
class AddUniqueIndexToConsentsTypePerParticipantEvent < ActiveRecord::Migration[8.1]
  def up
    # Keep the signed row (else the oldest) from any existing duplicate group.
    deleted = execute(<<~SQL).cmd_tuples
      DELETE FROM consents
      WHERE id IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (
            PARTITION BY participant_event_id, consent_type
            ORDER BY (status = 'signed') DESC, created_at ASC
          ) AS rank
          FROM consents
          WHERE custom_document_id IS NULL
        ) ranked
        WHERE rank > 1
      )
    SQL
    say "Deleted #{deleted} duplicate consent rows"

    add_index :consents, [ :participant_event_id, :consent_type ],
      unique: true,
      where: "custom_document_id IS NULL",
      name: "index_consents_on_pe_and_type_without_custom_document"
  end

  def down
    remove_index :consents, name: "index_consents_on_pe_and_type_without_custom_document"
  end
end
