class AddGenderFieldsToAccommodations < ActiveRecord::Migration[8.1]
  def change
    add_column :accommodations, :gender_identity, :string
    add_column :accommodations, :preferred_roommate_genders, :text, array: true, default: []
    remove_column :accommodations, :gender_preference, :string
  end
end
