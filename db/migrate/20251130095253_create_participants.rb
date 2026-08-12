class CreateParticipants < ActiveRecord::Migration[8.0]
  def change
    create_table :participants, id: :uuid, default: "gen_random_uuid()" do |t|
      t.uuid :user_id, null: true
      t.string :legal_first_name, null: false
      t.string :legal_last_name, null: false
      t.string :preferred_name
      t.date :date_of_birth, null: false
      t.string :email, null: false
      t.string :secondary_email
      t.string :phone
      t.string :pronouns
      t.string :country_of_residence
      t.string :city

      t.timestamps
    end

    add_index :participants, :email
    add_foreign_key :participants, :users, column: :user_id
  end
end
