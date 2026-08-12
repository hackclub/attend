class TicketMessage < ApplicationRecord
  has_paper_trail

  self.implicit_order_column = "created_at"

  encrypts :body

  has_many_attached :media

  belongs_to :ticket
  belongs_to :user, optional: true

  enum :direction, {
    inbound: "inbound",
    outbound: "outbound"
  }

  enum :channel, {
    sms: "sms",
    whatsapp: "whatsapp",
    signal: "signal"
  }

  validates :direction, presence: true
  validates :channel, presence: true
  validates :body, presence: true

  after_create_commit :broadcast_message
  after_create_commit :notify_assigned_user, if: :inbound?
  after_create_commit :notify_assigned_user_by_sms, if: :inbound?
  after_update_commit :broadcast_status_update, if: :saved_change_to_twilio_status?

  private

  def broadcast_message
    Rails.logger.info("[TicketMessage] Broadcasting to ticket #{ticket.id}, :messages -> target: ticket_#{ticket.id}_messages")

    broadcast_append_to(
      ticket,
      :messages,
      target: "ticket_#{ticket.id}_messages",
      partial: "support/tickets/message",
      locals: { message: self }
    )

    broadcast_replace_to(
      :tickets_index,
      target: "ticket_#{ticket.id}",
      partial: "support/tickets/ticket_row",
      locals: { ticket: ticket.reload }
    )
  end

  def broadcast_status_update
    broadcast_replace_to(
      ticket,
      :messages,
      target: "ticket_message_#{id}",
      partial: "support/tickets/message",
      locals: { message: self }
    )
  end

  def notify_assigned_user_by_sms
    return unless ticket.assigned_to.present?

    SendSupportTicketSmsNotificationJob.perform_later(id, "assigned_reply")
  end

  def notify_assigned_user
    return unless ticket.assigned_to.present?

    broadcast_append_to(
      "user_#{ticket.assigned_to.id}_notifications",
      target: "user_notifications",
      partial: "support/tickets/notification",
      locals: { ticket: ticket }
    )
  end
end
