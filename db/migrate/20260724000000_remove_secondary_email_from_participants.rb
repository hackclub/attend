class RemoveSecondaryEmailFromParticipants < ActiveRecord::Migration[8.1]
  def change
    remove_column :participants, :secondary_email, :string
  end
end
