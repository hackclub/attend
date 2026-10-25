class CreateConnectedAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :connected_accounts, id: :uuid do |t|
      t.references :participant, type: :uuid, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :uid, null: false
      t.string :username, null: false
      t.text :access_token, null: false
      t.string :scope
      t.jsonb :profile, default: {}, null: false
      t.datetime :connected_at, null: false
      t.timestamps
    end

    add_index :connected_accounts, [ :participant_id, :provider ], unique: true
    add_index :connected_accounts, [ :provider, :uid ]
  end
end
