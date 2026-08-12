class SlackBlastRecipient < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :slack_blast
  belongs_to :participant_event

  enum :status, {
    pending: "pending",
    sent: "sent",
    failed: "failed"
  }

  delegate :participant, to: :participant_event
end
