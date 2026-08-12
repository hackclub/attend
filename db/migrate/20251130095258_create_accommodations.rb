class CreateAccommodations < ActiveRecord::Migration[8.0]
  def change
    create_table :accommodations, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :participant_event, null: false, foreign_key: true, type: :uuid, index: true
      t.date :check_in_date
      t.date :check_out_date
      t.string :venue_name
      t.string :assigned_room
      t.string :room_type_preference
      t.text :roommate_preferences
      t.text :roommate_exclusions
      t.boolean :quiet_room_preference, default: false
      t.string :gender_preference
      t.string :airtable_record_id

      t.timestamps
    end
  end
end
