class AddHiddenFromPublicProfileToEventRoleAssignments < ActiveRecord::Migration[8.0]
  def change
    add_column :event_role_assignments, :hidden_from_public_profile, :boolean, default: false, null: false
  end
end
