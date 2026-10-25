class CreateAirtableConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :airtable_connections, id: :uuid do |t|
      t.references :event, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.references :connected_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :access_token, null: false
      t.text :refresh_token, null: false
      t.datetime :access_token_expires_at, null: false
      t.datetime :refresh_token_expires_at, null: false
      t.string :scope
      t.string :airtable_user_id
      t.string :airtable_email
      t.jsonb :bases, default: [], null: false
      t.timestamps
    end
  end
end
