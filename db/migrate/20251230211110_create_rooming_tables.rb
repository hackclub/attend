class CreateRoomingTables < ActiveRecord::Migration[8.1]
  def change
    # Sibling groups for tracking family relationships
    create_table :sibling_groups, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :label
      t.timestamps
    end

    create_table :sibling_memberships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :sibling_group_id, null: false
      t.uuid :participant_id, null: false
      t.timestamps
    end

    add_index :sibling_memberships, [ :sibling_group_id, :participant_id ], unique: true, name: "idx_sibling_memberships_unique"
    add_foreign_key :sibling_memberships, :sibling_groups
    add_foreign_key :sibling_memberships, :participants

    # Rooms per event
    create_table :rooms, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :event_id, null: false
      t.string :name
      t.integer :capacity, null: false, default: 2
      t.string :gender_label
      t.boolean :staff_only, default: false, null: false
      t.text :notes
      t.timestamps
    end

    add_index :rooms, :event_id
    add_index :rooms, [ :event_id, :name ], unique: true, where: "name IS NOT NULL"
    add_foreign_key :rooms, :events

    # Room assignments - one participant per room
    create_table :room_assignments, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :room_id, null: false
      t.uuid :participant_event_id, null: false
      t.boolean :staff_override, default: false, null: false
      t.text :staff_override_notes
      t.jsonb :flags, default: {}, null: false
      t.boolean :trans_nb_acknowledged, default: false, null: false
      t.timestamps
    end

    add_index :room_assignments, :room_id
    add_index :room_assignments, :participant_event_id, unique: true
    add_foreign_key :room_assignments, :rooms
    add_foreign_key :room_assignments, :participant_events

    # Normalized roommate preferences (from free-text)
    create_table :roommate_preferences, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :participant_event_id, null: false
      t.uuid :preferred_participant_event_id, null: false
      t.integer :rank
      t.boolean :admin_confirmed, default: false, null: false
      t.timestamps
    end

    add_index :roommate_preferences, [ :participant_event_id, :preferred_participant_event_id ],
              unique: true, name: "idx_roommate_prefs_unique_pair"
    add_foreign_key :roommate_preferences, :participant_events
    add_foreign_key :roommate_preferences, :participant_events, column: :preferred_participant_event_id

    # Normalized roommate exclusions (from free-text)
    create_table :roommate_exclusions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :participant_event_id, null: false
      t.uuid :excluded_participant_event_id, null: false
      t.boolean :admin_confirmed, default: false, null: false
      t.timestamps
    end

    add_index :roommate_exclusions, [ :participant_event_id, :excluded_participant_event_id ],
              unique: true, name: "idx_roommate_exclusions_unique_pair"
    add_foreign_key :roommate_exclusions, :participant_events
    add_foreign_key :roommate_exclusions, :participant_events, column: :excluded_participant_event_id

    # Rooming plan per event to track wizard state
    create_table :rooming_plans, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :event_id, null: false
      t.string :status, default: "draft", null: false
      t.integer :room_capacity, default: 2, null: false
      t.uuid :created_by_user_id
      t.uuid :finalized_by_user_id
      t.datetime :finalized_at
      t.jsonb :settings, default: {}, null: false
      t.timestamps
    end

    add_index :rooming_plans, :event_id, unique: true
    add_foreign_key :rooming_plans, :events
    add_foreign_key :rooming_plans, :users, column: :created_by_user_id
    add_foreign_key :rooming_plans, :users, column: :finalized_by_user_id

    # Add reviewed flag to accommodations
    add_column :accommodations, :roommate_links_reviewed, :boolean, default: false, null: false
  end
end
