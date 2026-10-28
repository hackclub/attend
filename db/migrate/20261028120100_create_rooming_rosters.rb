# Who's staying for an eligible-only stay (a pre- or post-event night), and
# why. Organizers pick the reasons per stay ("bought it in the shop", "paying
# $40", "other"); each roster entry says which one applied and where it came
# from: added by hand, a CSV/email paste, a group, or a shop calling the API.
class CreateRoomingRosters < ActiveRecord::Migration[8.1]
  def change
    create_table :rooming_eligibility_options, id: :uuid do |t|
      t.references :rooming_context, type: :uuid, null: false, foreign_key: true, index: false
      t.string :label, null: false
      t.integer :price_cents
      t.integer :position
      t.timestamps
    end
    add_index :rooming_eligibility_options, [ :rooming_context_id, :label ], unique: true

    create_table :rooming_roster_entries, id: :uuid do |t|
      t.references :rooming_context, type: :uuid, null: false, foreign_key: true, index: false
      t.references :participant_event, type: :uuid, null: false, foreign_key: true
      t.references :rooming_eligibility_option, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :source, null: false, default: "manual"
      t.string :external_reference
      t.text :notes
      t.references :added_by_user, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :rooming_roster_entries, [ :rooming_context_id, :participant_event_id ], unique: true, name: "index_rooming_roster_entries_one_per_person_per_context"
  end
end
