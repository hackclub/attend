class CreateIncidentComments < ActiveRecord::Migration[8.1]
  def change
    create_table :incident_comments, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :incident, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.text :body, null: false
      t.string :new_status

      t.timestamps
    end
  end
end
