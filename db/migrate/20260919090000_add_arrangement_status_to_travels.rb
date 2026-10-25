class AddArrangementStatusToTravels < ActiveRecord::Migration[8.1]
  def change
    add_column :travels, :arrangement_status, :string, null: false, default: "unknown"
  end
end
