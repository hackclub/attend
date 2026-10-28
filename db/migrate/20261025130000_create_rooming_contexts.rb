# A rooming context is one stay at an event: the main stay, a pre-event night,
# a post-event night. Plans, rooms and assignments used to hang straight off the
# event, which allowed exactly one stay and one room per person. They now each
# belong to a context, and a person can hold one room per context.
#
# Every event that already has a rooming plan or rooms gets a "Main stay"
# context (enrollment "everyone", today's behaviour) and its rows are pointed at
# it, so existing rooming carries on unchanged. Events without any rooming get
# their main context lazily, the first time the wizard or MCP needs one.
class CreateRoomingContexts < ActiveRecord::Migration[8.1]
  def up
    create_table :rooming_contexts, id: :uuid do |t|
      t.references :event, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.string :kind, null: false, default: "custom"
      t.string :enrollment, null: false, default: "eligible_only"
      t.date :starts_on
      t.date :ends_on
      t.integer :position
      t.timestamps
    end
    add_index :rooming_contexts, :event_id, unique: true, where: "kind = 'main'", name: "index_rooming_contexts_one_main_per_event"
    add_index :rooming_contexts, [ :event_id, :name ], unique: true

    add_reference :rooming_plans, :rooming_context, type: :uuid, foreign_key: true, index: false
    add_reference :rooms, :rooming_context, type: :uuid, foreign_key: true, index: false
    add_reference :room_assignments, :rooming_context, type: :uuid, foreign_key: true, index: false

    execute <<~SQL.squish
      INSERT INTO rooming_contexts (id, event_id, name, kind, enrollment, position, created_at, updated_at)
      SELECT gen_random_uuid(), events.id, 'Main stay', 'main', 'everyone', 0, NOW(), NOW()
      FROM events
      WHERE (
        EXISTS (SELECT 1 FROM rooming_plans WHERE rooming_plans.event_id = events.id)
        OR EXISTS (SELECT 1 FROM rooms WHERE rooms.event_id = events.id)
      )
      AND NOT EXISTS (
        SELECT 1 FROM rooming_contexts WHERE rooming_contexts.event_id = events.id AND rooming_contexts.kind = 'main'
      )
    SQL

    execute <<~SQL.squish
      UPDATE rooming_plans SET rooming_context_id = rooming_contexts.id
      FROM rooming_contexts
      WHERE rooming_contexts.event_id = rooming_plans.event_id AND rooming_contexts.kind = 'main'
        AND rooming_plans.rooming_context_id IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE rooms SET rooming_context_id = rooming_contexts.id
      FROM rooming_contexts
      WHERE rooming_contexts.event_id = rooms.event_id AND rooming_contexts.kind = 'main'
        AND rooms.rooming_context_id IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE room_assignments SET rooming_context_id = rooms.rooming_context_id
      FROM rooms
      WHERE rooms.id = room_assignments.room_id AND room_assignments.rooming_context_id IS NULL
    SQL

    change_column_null :rooming_plans, :rooming_context_id, false
    change_column_null :rooms, :rooming_context_id, false
    change_column_null :room_assignments, :rooming_context_id, false

    remove_index :rooming_plans, :event_id, name: "index_rooming_plans_on_event_id"
    add_index :rooming_plans, :event_id
    add_index :rooming_plans, :rooming_context_id, unique: true

    remove_index :rooms, name: "index_rooms_on_event_id_and_name"
    add_index :rooms, [ :rooming_context_id, :name ], unique: true, where: "name IS NOT NULL"
    add_index :rooms, :rooming_context_id

    remove_index :room_assignments, name: "index_room_assignments_on_participant_event_id"
    add_index :room_assignments, :participant_event_id
    add_index :room_assignments, [ :participant_event_id, :rooming_context_id ], unique: true, name: "index_room_assignments_one_per_person_per_context"
    add_index :room_assignments, :rooming_context_id
  end

  # Only safe while every event still has just its main context: with more
  # than one, a person can hold several assignments and the old unique index
  # can't come back.
  def down
    remove_index :room_assignments, name: "index_room_assignments_one_per_person_per_context"
    remove_index :room_assignments, :rooming_context_id
    remove_index :room_assignments, :participant_event_id
    add_index :room_assignments, :participant_event_id, unique: true

    remove_index :rooms, :rooming_context_id
    remove_index :rooms, [ :rooming_context_id, :name ]
    add_index :rooms, [ :event_id, :name ], unique: true, where: "name IS NOT NULL"

    remove_index :rooming_plans, :rooming_context_id
    remove_index :rooming_plans, :event_id
    add_index :rooming_plans, :event_id, unique: true

    remove_reference :room_assignments, :rooming_context, foreign_key: true
    remove_reference :rooms, :rooming_context, foreign_key: true
    remove_reference :rooming_plans, :rooming_context, foreign_key: true

    drop_table :rooming_contexts
  end
end
