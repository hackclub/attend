class CreateMcpConnectionSettings < ActiveRecord::Migration[8.1]
  def change
    # Per-connection privacy settings for the MCP server. A "connection" is one
    # OAuth client application authorized by one user, which is the same unit the
    # profile page lists and revokes — the row therefore outlives the short-lived
    # access tokens the client keeps refreshing.
    create_table :mcp_connection_settings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :application, null: false,
        foreign_key: { to_table: :toolchest_oauth_applications }, index: false
      t.string  :resource_owner_id, null: false
      # When false, the connection only reaches the events in mcp_connection_events.
      t.boolean :all_events, null: false, default: true
      # Strips names down to initials and removes contact details from every
      # response. One-way: the MCP server can turn it on, never off.
      t.boolean :anonymize, null: false, default: false
      t.datetime :anonymize_enabled_at
      t.string :anonymize_enabled_by, comment: "consent | dashboard | mcp"
      t.timestamps

      t.index [ :application_id, :resource_owner_id ], unique: true,
        name: "index_mcp_connection_settings_on_application_and_owner"
    end

    create_table :mcp_connection_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :mcp_connection_setting, null: false, type: :uuid,
        foreign_key: true, index: false
      t.references :event, null: false, type: :uuid, foreign_key: true
      t.timestamps

      t.index [ :mcp_connection_setting_id, :event_id ], unique: true,
        name: "index_mcp_connection_events_on_setting_and_event"
    end
  end
end
