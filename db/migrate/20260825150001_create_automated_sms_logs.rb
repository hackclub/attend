class CreateAutomatedSmsLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :automated_sms_logs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :phone_number, null: false
      t.text :body, null: false
      t.string :twilio_sid
      t.string :source
      t.datetime :sent_at, null: false

      t.timestamps
    end

    add_index :automated_sms_logs, [ :phone_number, :sent_at ]
    add_index :automated_sms_logs, :twilio_sid, unique: true, where: "twilio_sid IS NOT NULL"
  end
end
