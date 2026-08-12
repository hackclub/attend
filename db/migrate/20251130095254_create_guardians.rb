class CreateGuardians < ActiveRecord::Migration[8.0]
  def change
    create_table :guardians, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :user, type: :uuid, null: true, foreign_key: true
      t.string :legal_first_name, null: false
      t.string :legal_last_name, null: false
      t.string :email, null: false
      t.string :phone
      t.string :relationship_default
      t.string :country
      t.string :time_zone, default: "UTC"

      t.timestamps
    end

    add_index :guardians, :email
  end
end
