class AddRevocationToBans < ActiveRecord::Migration[8.1]
  def change
    add_column :bans, :revoked_at, :datetime
    add_reference :bans, :revoked_by, type: :uuid, null: true, foreign_key: { to_table: :users }
    add_index :bans, :revoked_at
  end
end
