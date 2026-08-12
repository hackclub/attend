class ScrubTerminalImportBatchRows < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE import_batches
      SET rows_data = '[]'::jsonb
      WHERE status IN ('completed', 'failed')
    SQL
  end

  def down
  end
end
