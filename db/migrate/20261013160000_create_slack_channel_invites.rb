class CreateSlackChannelInvites < ActiveRecord::Migration[8.1]
  # Who Attend itself put in a Slack channel, so a sync only ever removes
  # people it added — never someone who joined the channel on their own.
  def change
    create_table :slack_channel_invites, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, index: false, foreign_key: { on_delete: :cascade }
      t.string :channel_id, null: false
      t.string :slack_user_id, null: false
      t.timestamps
    end

    add_index :slack_channel_invites, %i[user_id channel_id], unique: true
    add_index :slack_channel_invites, :channel_id
  end
end
