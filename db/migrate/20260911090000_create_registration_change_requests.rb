class CreateRegistrationChangeRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :registration_change_requests, id: :uuid do |t|
      t.references :participant_event, null: false, type: :uuid, foreign_key: true
      t.references :requested_by, null: false, type: :uuid, foreign_key: { to_table: :users }
      t.references :resolved_by, type: :uuid, foreign_key: { to_table: :users }
      t.string :kind, null: false
      t.string :status, null: false, default: "pending"
      t.string :staff_audience, null: false
      t.jsonb :requested_changes, null: false, default: {}
      t.text :requester_note
      t.text :staff_response
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :registration_change_requests,
      [ :participant_event_id, :kind ],
      unique: true,
      where: "status = 'pending'",
      name: "index_pending_registration_change_requests"
    add_index :registration_change_requests, [ :status, :created_at ]
  end
end
