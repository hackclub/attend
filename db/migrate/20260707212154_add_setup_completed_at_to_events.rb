class AddSetupCompletedAtToEvents < ActiveRecord::Migration[8.1]
  def up
    add_column :events, :setup_completed_at, :datetime
    # Existing events predate the setup wizard — treat them all as fully set up
    execute "UPDATE events SET setup_completed_at = updated_at"
  end

  def down
    remove_column :events, :setup_completed_at
  end
end
