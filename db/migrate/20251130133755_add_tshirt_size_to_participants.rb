class AddTshirtSizeToParticipants < ActiveRecord::Migration[8.1]
  def change
    add_column :participants, :tshirt_size, :string
  end
end
