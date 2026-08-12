class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages, id: :uuid do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid
      t.references :sent_by_user, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.string :subject
      t.text :body, null: false
      t.string :audience, null: false
      t.jsonb :audience_filters, default: {}
      t.string :channels, array: true, default: []
      t.string :status, default: "draft"
      t.datetime :scheduled_at
      t.datetime :sent_at
      t.integer :recipient_count, default: 0
      t.integer :sent_count, default: 0
      t.integer :failed_count, default: 0
      t.timestamps
    end

    add_index :messages, :status
    add_index :messages, :scheduled_at

    create_table :message_deliveries, id: :uuid do |t|
      t.references :message, null: false, foreign_key: true, type: :uuid
      t.references :participant_event, foreign_key: true, type: :uuid
      t.references :guardian, foreign_key: true, type: :uuid
      t.string :channel, null: false
      t.string :recipient_email
      t.string :recipient_phone
      t.string :recipient_slack_id
      t.string :status, default: "pending"
      t.text :error_message
      t.string :external_id
      t.datetime :delivered_at
      t.timestamps
    end

    add_index :message_deliveries, :status
    add_index :message_deliveries, [ :message_id, :channel ]
  end
end
