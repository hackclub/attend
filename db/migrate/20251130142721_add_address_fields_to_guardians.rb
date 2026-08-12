class AddAddressFieldsToGuardians < ActiveRecord::Migration[8.1]
  def change
    add_column :guardians, :address_line_1, :string
    add_column :guardians, :address_line_2, :string
    add_column :guardians, :city, :string
    add_column :guardians, :state, :string
    add_column :guardians, :postal_code, :string
  end
end
