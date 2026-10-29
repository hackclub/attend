# The tables DropCutoverLeftovers drops. `db:schema:load` leaves a table that
# isn't in schema.rb where it is and marks every migration as run, so a database
# that had these before a load keeps them after it. Left to itself, the next
# dump would write them back into schema.rb and every test database would have
# them again, which production doesn't.
ActiveRecord::SchemaDumper.ignore_tables += %w[
  hospitality_acts hospitality_redemptions hospitality_rewards nfc_tokens flipper_gates flipper_features
]
