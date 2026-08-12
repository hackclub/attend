class CreateEventApiTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :event_api_tokens, id: :uuid do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid
      t.references :user, null: true, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :event_api_tokens, :token_digest, unique: true
    add_index :event_api_tokens, [ :event_id, :revoked_at ]
  end
end
