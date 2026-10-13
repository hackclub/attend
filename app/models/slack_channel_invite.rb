# Records that Attend invited a user to a Slack channel, so the channel sync
# can later remove them. Anyone already in the channel when we tried to invite
# them has no row and is never removed.
class SlackChannelInvite < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :user

  validates :channel_id, :slack_user_id, presence: true
  validates :user_id, uniqueness: { scope: :channel_id }
end
