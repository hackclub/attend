class DropFlipperTables < ActiveRecord::Migration[8.1]
  # Leftovers from a dev-only feature flag that never shipped: the tables reached
  # schema.rb during the open-source cutover, so a fresh `db:schema:load` created
  # them even though nothing in the app has ever referenced flipper. `if_exists`
  # keeps this a no-op on databases that never had them.
  def up
    drop_table :flipper_gates, if_exists: true
    drop_table :flipper_features, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
