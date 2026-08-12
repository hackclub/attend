class AddClientScanIdToScans < ActiveRecord::Migration[8.1]
  def change
    add_column :scans, :client_scan_id, :string
    add_index :scans, :client_scan_id, unique: true, where: "client_scan_id IS NOT NULL"
  end
end
