class CreateIncidentReportComments < ActiveRecord::Migration[8.1]
  def change
    create_table :incident_report_comments, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :incident_report, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: true, foreign_key: true
      t.text :body, null: false
      t.string :new_status
      t.string :source
      t.string :slack_user_id
      t.string :slack_display_name
      t.string :slack_avatar_url
      t.string :slack_channel_id
      t.string :slack_message_ts
      t.timestamps
    end

    add_column :incident_reports, :acknowledgements, :jsonb, default: [], null: false
  end
end
