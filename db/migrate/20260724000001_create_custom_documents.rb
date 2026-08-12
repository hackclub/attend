class CreateCustomDocuments < ActiveRecord::Migration[8.1]
  # Originally shipped as 20260724000000, which collided with
  # RemoveSecondaryEmailFromParticipants. Renumbered, and guarded so it is a
  # no-op in environments that already applied it under the old version.
  def change
    create_table :custom_documents, id: :uuid, if_not_exists: true do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :docuseal_template_id, null: false
      t.string :signer_type, null: false, default: "participant"
      t.datetime :archived_at

      t.timestamps
    end

    add_reference :consents, :custom_document, foreign_key: true, type: :uuid, if_not_exists: true
    add_index :consents, [ :participant_event_id, :custom_document_id ],
              unique: true, where: "custom_document_id IS NOT NULL",
              name: "index_consents_on_pe_and_custom_document",
              if_not_exists: true
  end
end
