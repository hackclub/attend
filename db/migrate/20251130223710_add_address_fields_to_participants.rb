class AddAddressFieldsToParticipants < ActiveRecord::Migration[8.1]
  def change
    add_column :participants, :address_line_1, :string
    add_column :participants, :address_line_2, :string
    add_column :participants, :state, :string
    add_column :participants, :postal_code, :string
  end
end
