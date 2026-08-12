class AddGroupIdsToInvitations < ActiveRecord::Migration[8.1]
  def change
    add_column :invitations, :group_ids, :uuid, array: true, default: []
  end
end
