class CreateGlobalApiTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :global_api_tokens, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :token_digest, null: false
      t.string :name
      t.datetime :last_used_at
      t.datetime :expires_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :global_api_tokens, :token_digest, unique: true
    add_index :global_api_tokens, [ :user_id, :revoked_at ]
  end
end
