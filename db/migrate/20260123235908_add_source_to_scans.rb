class AddSourceToScans < ActiveRecord::Migration[8.1]
  def change
    add_column :scans, :source, :string, default: "qr"
  end
end
