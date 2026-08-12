class AddScanContextToScans < ActiveRecord::Migration[8.1]
  def change
    add_reference :scans, :scan_context, type: :uuid, foreign_key: true, null: true
  end
end
