class CreateAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_logs, id: :uuid, default: "gen_random_uuid()" do |t|
      t.uuid :actor_user_id
      t.uuid :event_id
      t.string :record_type, null: false
      t.uuid :record_id, null: false
      t.string :action, null: false
      t.jsonb :changed_fields, default: {}
      t.jsonb :metadata, default: {}
      t.datetime :created_at, null: false
    end

    add_foreign_key :audit_logs, :users, column: :actor_user_id
    add_foreign_key :audit_logs, :events, column: :event_id

    add_index :audit_logs, :event_id
    add_index :audit_logs, :record_type
    add_index :audit_logs, :record_id
    add_index :audit_logs, [ :record_type, :record_id ]
    add_index :audit_logs, :created_at
  end
end
