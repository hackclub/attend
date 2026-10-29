class DropCutoverLeftovers < ActiveRecord::Migration[8.1]
  # Leftovers from dev-only work that never shipped: no migration creates these
  # tables or columns, so production never had them, but they reached schema.rb
  # during the open-source cutover and every `db:schema:load` has recreated them
  # since. RenameAirportPickupToTravelPickup renamed is_airport, but the cutover
  # dump kept the old column next to the new one.
  # DropFlipperTables didn't clear flipper's: `db:schema:load` marks every
  # migration up to the schema version as run, so it never ran on a database
  # loaded from that schema. `if_exists` keeps this a no-op in production.
  TABLES = %w[hospitality_acts hospitality_redemptions hospitality_rewards nfc_tokens flipper_gates flipper_features].freeze

  # each column, with the condition that means a row holds something in it
  COLUMNS = {
    %w[participant_events totp_secret] => "totp_secret IS NOT NULL",
    %w[scan_contexts is_airport] => "is_airport"
  }.freeze

  def up
    # Production is only assumed not to have these. If one is there and holds
    # data, stop before dropping anything, so a person decides what happens to it
    held = TABLES.select { |table| connection.table_exists?(table) && holds_data?(table) } +
      COLUMNS.filter_map { |(table, column), condition| "#{table}.#{column}" if connection.column_exists?(table, column) && holds_data?(table, condition) }
    if held.any?
      raise "Leftovers still holding data, so nothing was dropped: #{held.join(", ")}. " \
            "Nothing in the app reads them: keep what's worth keeping, empty them and migrate again."
    end

    TABLES.each { |table| drop_table table, if_exists: true }
    COLUMNS.each_key { |table, column| remove_column table, column, if_exists: true }
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def holds_data?(table, condition = "TRUE")
    connection.select_value("SELECT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)} WHERE #{condition})")
  end
end
