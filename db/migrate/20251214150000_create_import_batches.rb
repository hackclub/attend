class CreateImportBatches < ActiveRecord::Migration[8.0]
  def change
    create_table :import_batches, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid
      t.string :status, null: false, default: "pending"
      t.integer :total_count, null: false, default: 0
      t.integer :imported_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.integer :error_count, null: false, default: 0
      t.integer :invites_sent_count, null: false, default: 0
      t.jsonb :rows_data, null: false, default: []
      t.jsonb :errors_data, null: false, default: []
      t.boolean :send_invitations, null: false, default: true
      t.datetime :completed_at

      t.timestamps
    end
  end
end
