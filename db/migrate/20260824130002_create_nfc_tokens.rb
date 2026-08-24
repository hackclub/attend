class CreateNfcTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :nfc_tokens, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :token, null: false, default: -> { "gen_random_uuid()" }
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.datetime :paired_at
      t.references :paired_by, foreign_key: { to_table: :users }, type: :uuid
      t.datetime :revoked_at
      t.references :revoked_by, foreign_key: { to_table: :users }, type: :uuid

      t.timestamps
    end

    add_index :nfc_tokens, :token, unique: true
  end
end
