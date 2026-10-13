# Records that Attend invited a Slack account to a channel, so the channel
# sync can later remove it. Anyone already in the channel when we tried to
# invite them has no row and is never removed. The user is nulled if they're
# deleted, leaving the row for the next sync to remove.
class SlackChannelInvite < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :user, optional: true

  validates :channel_id, :slack_user_id, presence: true
  validates :slack_user_id, uniqueness: { scope: :channel_id }
end
