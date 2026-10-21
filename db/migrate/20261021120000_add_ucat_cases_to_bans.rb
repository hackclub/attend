class AddUcatCasesToBans < ActiveRecord::Migration[8.1]
  def change
    # The UCAT cases behind a synced ban, as [{ "id" => "<case ID>",
    # "record_id" => "rec..." }], so the admin UI can link back to each
    # Airtable record. Filled by the next sync run for existing rows.
    add_column :bans, :ucat_cases, :jsonb, default: [], null: false
  end
end
