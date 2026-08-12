class CreateSlackBlastRecipients < ActiveRecord::Migration[8.1]
  def change
    create_table :slack_blast_recipients, id: :uuid do |t|
      t.references :slack_blast, null: false, foreign_key: true, type: :uuid
      t.references :participant_event, null: false, foreign_key: true, type: :uuid
      t.string :status, default: "pending"
      t.text :error_message
      t.string :slack_message_ts

      t.timestamps
    end
  end
end
