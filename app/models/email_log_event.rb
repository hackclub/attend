class EmailLogEvent < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :email_log

  enum :event_type, {
    sent: "sent",
    delivered: "delivered",
    opened: "opened",
    bounced: "bounced",
    link_clicked: "link_clicked",
    spam_complaint: "spam_complaint"
  }

  validates :event_type, :occurred_at, presence: true

  scope :chronological, -> { order(occurred_at: :asc) }
end
