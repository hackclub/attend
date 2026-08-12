class CreateEmailLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :email_logs, id: :uuid do |t|
      t.string :to_address, null: false
      t.string :from_address, null: false
      t.string :subject, null: false
      t.string :mailer_class, null: false
      t.string :mailer_action, null: false
      t.string :postmark_message_id
      t.string :status, default: "sent", null: false
      t.datetime :delivered_at
      t.datetime :opened_at
      t.datetime :bounced_at
      t.string :bounce_type
      t.text :bounce_description
      t.references :emailable, polymorphic: true, type: :uuid
      t.references :event, type: :uuid, foreign_key: true

      t.timestamps
    end

    add_index :email_logs, :postmark_message_id, unique: true, where: "postmark_message_id IS NOT NULL"
    add_index :email_logs, :to_address
    add_index :email_logs, :status
    add_index :email_logs, :mailer_class
  end
end
