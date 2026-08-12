class CreateSlackBlasts < ActiveRecord::Migration[8.1]
  def change
    create_table :slack_blasts, id: :uuid do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid
      t.references :sent_by_user, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.text :message
      t.string :status, default: "pending"
      t.integer :recipient_count, default: 0
      t.integer :sent_count, default: 0
      t.integer :failed_count, default: 0

      t.timestamps
    end
  end
end
