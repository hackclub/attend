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
      t.references :ban, type: :uuid, null: false, foreign_key: true, index: false
      t.string :slack_id, null: false
      t.timestamps
    end
    add_index :ban_slack_ids, [ :ban_id, :slack_id ], unique: true
    add_index :ban_slack_ids, :slack_id

    # An identifier may now sit on more than one ban (a synced ban alongside a
    # lapsed or revoked manual one), so uniqueness is per ban. Ban.banned?
    # already checks across all bans.
    reversible do |dir|
      dir.up do
        remove_index :ban_emails, name: "index_ban_emails_on_lower_email"
        add_index :ban_emails, "lower((email)::text)", name: "index_ban_emails_on_lower_email"
      end
      dir.down do
        remove_index :ban_emails, name: "index_ban_emails_on_lower_email"
        add_index :ban_emails, "lower((email)::text)", name: "index_ban_emails_on_lower_email", unique: true
      end
    end
    add_index :ban_emails, "ban_id, lower((email)::text)", unique: true, name: "index_ban_emails_on_ban_id_and_lower_email"
  end
end
