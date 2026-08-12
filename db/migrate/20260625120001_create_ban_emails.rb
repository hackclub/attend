class CreateBanEmails < ActiveRecord::Migration[8.1]
  def change
    create_table :ban_emails, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :ban, type: :uuid, null: false, foreign_key: true
      t.string :email, null: false
      t.timestamps
    end

    add_index :ban_emails, "LOWER(email)", unique: true, name: "index_ban_emails_on_lower_email"
  end
end
