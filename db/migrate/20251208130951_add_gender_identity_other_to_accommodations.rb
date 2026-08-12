class AddGenderIdentityOtherToAccommodations < ActiveRecord::Migration[8.1]
  def change
    add_column :accommodations, :gender_identity_other, :string
  end
end
