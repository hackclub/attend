class CreateSlackChannelInvites < ActiveRecord::Migration[8.1]
  # Who Attend itself put in a Slack channel, so a sync only ever removes
  # people it added — never someone who joined the channel on their own. One
  # row per Slack account, and user_id is nulled rather than cascaded, so a
  # deleted user or a changed Slack ID still leaves a row to remove.
  def change
    create_table :slack_channel_invites, id: :uuid do |t|
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :channel_id, null: false
      t.string :slack_user_id, null: false
      t.timestamps
    end

    add_index :slack_channel_invites, %i[channel_id slack_user_id], unique: true
  end
end
