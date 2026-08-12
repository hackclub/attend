class MessageDelivery < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :message
  belongs_to :participant_event, optional: true
  belongs_to :guardian, optional: true

  enum :status, {
    pending: "pending",
    sending: "sending",
    delivered: "delivered",
    failed: "failed"
  }

  validates :channel, presence: true
  validate :has_recipient

  scope :for_channel, ->(channel) { where(channel: channel) }
  scope :unread, -> { where(read_at: nil) }
  scope :read, -> { where.not(read_at: nil) }

  def read?
    read_at.present?
  end

  def mark_as_read!
    update!(read_at: Time.current) unless read?
  end

  delegate :event, to: :message

  def recipient
    participant_event&.participant || guardian
  end

  def recipient_name
    recipient.try(:display_name) || recipient.try(:full_name) || recipient_email || "Unknown"
  end

  def recipient_identifier
    case channel
    when "slack"
      recipient_slack_id
    when "email"
      recipient_email
    when "sms"
      recipient_phone
    end
  end

  private

  def has_recipient
    unless participant_event.present? || guardian.present?
      errors.add(:base, "must have a participant_event or guardian")
    end
  end
end
