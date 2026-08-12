class CreateIncidents < ActiveRecord::Migration[8.0]
  def change
    create_table :incidents, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :event, type: :uuid, null: false, foreign_key: true, index: true
      t.references :participant_event, type: :uuid, null: true, foreign_key: true
      t.references :reported_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :category, null: false
      t.string :severity, null: false
      t.datetime :occurred_at
      t.string :location
      t.text :summary
      t.text :details
      t.text :actions_taken
      t.string :status, default: "open", null: false
      t.string :visible_to_roles, array: true, default: []

      t.timestamps
    end
  end
end
