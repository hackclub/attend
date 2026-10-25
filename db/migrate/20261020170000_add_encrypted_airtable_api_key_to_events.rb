# The Airtable personal access token lived in the events.config jsonb, so it
# was stored in plaintext and copied into every PaperTrail version and admin
# audit log written for the event. It moves to its own encrypted column.
#
# This only copies. Old pods keep reading config during the rolling deploy, so
# the plaintext is removed afterwards by `rails airtable:scrub_leaked_tokens`.
class AddEncryptedAirtableApiKeyToEvents < ActiveRecord::Migration[8.1]
  class MigrationEvent < ActiveRecord::Base
    self.table_name = "events"
    encrypts :airtable_api_key
  end

  def up
    add_column :events, :airtable_api_key, :text

    MigrationEvent.reset_column_information
    MigrationEvent.where("NULLIF(BTRIM(config ->> 'airtable_api_key'), '') IS NOT NULL").find_each do |event|
      token = event.config["airtable_api_key"].to_s.strip.presence
      event.update_columns(airtable_api_key: token) if token
    end
  end

  def down
    remove_column :events, :airtable_api_key
  end
end
