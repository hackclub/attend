class CreateAccessibilities < ActiveRecord::Migration[8.0]
  def change
    create_table :accessibilities, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :participant_event, null: false, foreign_key: true, type: :uuid, index: true

      t.text :mobility_needs
      t.boolean :step_free_required, default: false
      t.boolean :uses_wheelchair, default: false
      t.text :distance_limitations

      t.text :sensory_needs
      t.boolean :noise_sensitivity, default: false
      t.boolean :light_sensitivity, default: false
      t.boolean :strobe_sensitivity, default: false

      t.text :communication_needs
      t.boolean :needs_captioning, default: false
      t.boolean :needs_sign_language, default: false
      t.boolean :needs_large_print, default: false

      t.text :religious_practices
      t.boolean :prayer_space_required, default: false
      t.text :unavailable_times

      t.text :other_needs
      t.boolean :requires_private_space, default: false

      t.timestamps
    end
  end
end
