# Every change to a registration's status, with why it happened and who (if
# anyone) did it. PaperTrail already keeps who and when; this adds the cause,
# which later decides what a transition sets off.
class CreateRegistrationTransitions < ActiveRecord::Migration[8.1]
  def change
    create_table :registration_transitions, id: :uuid do |t|
      t.references :participant_event, null: false, type: :uuid, index: false,
        foreign_key: { on_delete: :cascade }
      t.references :actor, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :from_status
      t.string :to_status, null: false
      t.string :cause, null: false
      t.string :blocking_requirement
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :registration_transitions, [ :participant_event_id, :created_at ],
      name: "index_registration_transitions_on_registration_and_time"
  end
end
