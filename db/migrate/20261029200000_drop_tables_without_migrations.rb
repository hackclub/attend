class DropTablesWithoutMigrations < ActiveRecord::Migration[8.1]
  # Leftovers from dev-only features that never shipped: no migration creates
  # these, so production never had them, but they reached schema.rb during the
  # open-source cutover and every `db:schema:load` has recreated them since.
  # DropFlipperTables didn't clear flipper's: `db:schema:load` marks every
  # migration up to the schema version as run, so it never ran on a database
  # loaded from that schema. `if_exists` keeps this a no-op in production.
  def up
    drop_table :hospitality_acts, if_exists: true
    drop_table :hospitality_redemptions, if_exists: true
    drop_table :hospitality_rewards, if_exists: true
    drop_table :nfc_tokens, if_exists: true
    drop_table :flipper_gates, if_exists: true
    drop_table :flipper_features, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
