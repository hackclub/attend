class CreateEmailLogEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :email_log_events, id: :uuid do |t|
      t.references :email_log, null: false, foreign_key: true, type: :uuid
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :email_log_events, :event_type
    add_index :email_log_events, :occurred_at
  end
end
