class CreateSeriesApiTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :series_api_tokens, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :event_series, type: :uuid, null: false, foreign_key: true
      # The user who created the token. Nullable so a token outlives its
      # creator's account, but retained for the display name and audit context.
      # ON DELETE SET NULL rather than plain FK: a deleted organizer must not
      # take a whole series' integration down with them.
      t.references :user, type: :uuid, null: true,
                   foreign_key: { on_delete: :nullify }
      t.string :name, null: false
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :series_api_tokens, :token_digest, unique: true
    add_index :series_api_tokens, [ :event_series_id, :revoked_at ]
  end
end
