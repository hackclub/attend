class AddUniqueIndexToScansId < ActiveRecord::Migration[8.1]
  def change
    add_index :scans, :id, unique: true
  end
end
