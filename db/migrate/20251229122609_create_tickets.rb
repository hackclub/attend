class CreateTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :tickets, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :status, null: false, default: "open"
      t.string :channel, null: false # "sms", "whatsapp"
      t.string :phone_number, null: false # E.164 normalized

      t.references :event, type: :uuid, foreign_key: true, null: true
      t.string :subject_type # Participant or Guardian (polymorphic)
      t.uuid :subject_id

      t.references :assigned_to, type: :uuid, foreign_key: { to_table: :users }, null: true
      t.references :created_by, type: :uuid, foreign_key: { to_table: :users }, null: true
      t.references :closed_by, type: :uuid, foreign_key: { to_table: :users }, null: true
      t.datetime :closed_at

      t.string :twilio_to_number # which Twilio number this conversation uses
      t.datetime :last_inbound_at
      t.datetime :last_outbound_at
      t.datetime :last_message_at

      t.timestamps
    end

    add_index :tickets, :status
    add_index :tickets, :phone_number
    add_index :tickets, [ :subject_type, :subject_id ]
    add_index :tickets, [ :channel, :phone_number, :status ], name: "idx_tickets_by_phone_chan_status"
  end
end
