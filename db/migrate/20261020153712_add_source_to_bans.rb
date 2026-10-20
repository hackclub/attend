class AddSourceToBans < ActiveRecord::Migration[8.1]
  def change
    add_column :bans, :source, :string, null: false, default: "manual"
    # Identifies a synced ban within its source, so the nightly sync can find,
    # revoke and reinstate its own rows.
    add_column :bans, :external_key, :string
    add_index :bans, [ :source, :external_key ], unique: true, where: "external_key IS NOT NULL"

    # Conduct cases often carry only a Slack ID; Attend learns participants'
    # Slack IDs from Hack Club Auth, so bans can match on either.
    create_table :ban_slack_ids, id: :uuid do |t|
      t.references :ban, type: :uuid, null: false, foreign_key: true
      t.string :slack_id, null: false
      t.timestamps
    end
    add_index :ban_slack_ids, :slack_id, unique: true
  end
end
