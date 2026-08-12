class CreateSafeguardingInfos < ActiveRecord::Migration[8.0]
  def change
    create_table :safeguarding_infos, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :participant_event, type: :uuid, null: false, foreign_key: true, index: true
      t.boolean :freedom_waiver_granted, default: false
      t.boolean :can_leave_unaccompanied, default: false
      t.text :authorized_pickup_adults
      t.boolean :curfew_acknowledged, default: false
      t.boolean :overnight_rules_acknowledged, default: false
      t.text :other_instructions
      t.boolean :high_support_flag, default: false
      t.text :high_support_notes

      t.timestamps
    end
  end
end
