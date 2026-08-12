class AddLockedToRoomingPlans < ActiveRecord::Migration[8.1]
  def change
    add_column :rooming_plans, :locked, :boolean, default: false, null: false
  end
end
