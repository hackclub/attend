class CreateTicketMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :ticket_messages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :ticket, type: :uuid, null: false, foreign_key: true
      t.string :direction, null: false # "inbound", "outbound"
      t.string :channel, null: false # "sms", "whatsapp"
      t.text :body, null: false

      t.references :user, type: :uuid, foreign_key: true, null: true # for outbound: which staff user sent it
      t.string :twilio_message_sid
      t.string :twilio_status # queued/sent/delivered/failed
      t.text :error_message
      t.jsonb :raw_payload, default: {}

      t.datetime :sent_at

      t.timestamps
    end

    add_index :ticket_messages, :direction
    add_index :ticket_messages, :twilio_message_sid, unique: true, where: "twilio_message_sid IS NOT NULL"
  end
end
