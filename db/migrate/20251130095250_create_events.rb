class CreateEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :events, id: :uuid, default: "gen_random_uuid()" do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.datetime :starts_at
      t.datetime :ends_at
      t.string :location_city
      t.string :location_country
      t.string :timezone, default: "UTC"
      t.string :luma_event_id
      t.text :luma_api_key_encrypted
      t.string :docuseal_consent_template_id
      t.string :docuseal_waiver_template_id
      t.string :docuseal_participant_template_id
      t.datetime :registration_open_at
      t.datetime :registration_close_at
      t.jsonb :config, default: {}

      t.timestamps
    end

    add_index :events, :slug, unique: true
  end
end
