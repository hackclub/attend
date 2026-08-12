class DefaultScanContextChecksInToFalse < ActiveRecord::Migration[8.1]
  def change
    change_column_default :scan_contexts, :checks_in, from: true, to: false
  end
end
