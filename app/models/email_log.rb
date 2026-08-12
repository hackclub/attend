class EmailLog < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :emailable, polymorphic: true, optional: true
  belongs_to :event, optional: true
  has_many :email_log_events, dependent: :destroy

  enum :status, {
    sent: "sent",
    delivered: "delivered",
    opened: "opened",
    bounced: "bounced",
    failed: "failed"
  }

  validates :to_address, :from_address, :subject, :mailer_class, :mailer_action, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_event, ->(event) { where(event: event) }
end
