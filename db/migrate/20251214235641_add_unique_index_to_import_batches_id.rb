class AddUniqueIndexToImportBatchesId < ActiveRecord::Migration[8.1]
  def change
    add_index :import_batches, :id, unique: true
  end
end
