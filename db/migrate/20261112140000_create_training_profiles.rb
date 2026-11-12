class CreateTrainingProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :training_profiles, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :full_name, null: false
      t.string :connection_type, null: false
      t.text :connection_detail, null: false
      t.text :phone_number, null: false
      t.text :address_line_1, null: false
      t.text :address_line_2
      t.text :city, null: false
      t.text :state
      t.text :postal_code
      t.text :country, null: false
      t.timestamps
    end
  end
end
