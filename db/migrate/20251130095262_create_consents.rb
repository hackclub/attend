class CreateConsents < ActiveRecord::Migration[8.0]
  def change
    create_table :consents, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :participant_event, type: :uuid, null: false, foreign_key: true, index: true
      t.references :guardian_participant_event, type: :uuid, foreign_key: true
      t.string :consent_type, null: false
      t.string :docuseal_envelope_id
      t.string :docuseal_template_id
      t.string :status, default: "pending"
      t.datetime :sent_at
      t.datetime :signed_at
      t.string :document_url
      t.boolean :media_consent_granted
      t.boolean :media_public_use_granted
      t.jsonb :raw_metadata, default: {}

      t.timestamps
    end
  end
end
