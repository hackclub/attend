class Ticket < ApplicationRecord
  include ActionView::RecordIdentifier

  has_paper_trail

  self.implicit_order_column = "created_at"

  belongs_to :event, optional: true
  belongs_to :subject, polymorphic: true, optional: true # Participant or Guardian
  belongs_to :assigned_to, class_name: "User", optional: true
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :closed_by, class_name: "User", optional: true

  has_many :ticket_messages, dependent: :destroy
  has_many :notes, dependent: :nullify

  enum :status, {
    open: "open",
    closed: "closed"
  }

  enum :channel, {
    sms: "sms",
    whatsapp: "whatsapp",
    signal: "signal"
  }

  validates :phone_number, presence: true
  validates :channel, presence: true
  validates :status, presence: true

  scope :recent_first, -> { order(last_message_at: :desc, created_at: :desc) }

  after_create_commit :broadcast_new_ticket
  after_update_commit :broadcast_ticket_update

  private

  def broadcast_new_ticket
    broadcast_prepend_to(
      :tickets_index,
      target: "tickets",
      partial: "support/tickets/ticket_row",
      locals: { ticket: self }
    )

    broadcast_append_to(
      :tickets_notifications,
      target: "ticket_notifications",
      partial: "support/tickets/notification",
      locals: { ticket: self }
    )
  end

  def broadcast_ticket_update
    broadcast_replace_to(
      :tickets_index,
      target: dom_id(self),
      partial: "support/tickets/ticket_row",
      locals: { ticket: self }
    )
  end

  public

  def close!(user:)
    update!(status: :closed, closed_at: Time.current, closed_by: user)
  end

  def reopen!
    update!(status: :open, closed_at: nil, closed_by: nil)
  end

  # WhatsApp only accepts freeform outbound messages within 24 hours of the
  # contact's last inbound message. After that Meta rejects anything that
  # isn't a pre-approved template, and Twilio reports error 63016.
  WHATSAPP_FREEFORM_WINDOW = 24.hours

  def whatsapp_window_expires_at
    return nil unless whatsapp?
    return nil if last_inbound_at.blank?

    last_inbound_at + WHATSAPP_FREEFORM_WINDOW
  end

  def whatsapp_window_open?
    expires_at = whatsapp_window_expires_at

    expires_at.present? && expires_at.future?
  end

  # True when a plain text reply would be rejected by WhatsApp.
  def freeform_reply_blocked?
    whatsapp? && !whatsapp_window_open?
  end

  def matching_participants
    Participant.where(phone: phone_number).includes(:participant_events, :events)
  end

  def matching_guardians
    Guardian.where(phone: phone_number).includes(:guardian_participant_events, :participant_events, :participants)
  end

  def all_linked_participants
    participants = matching_participants.to_a

    matching_guardians.find_each do |guardian|
      guardian.participants.each do |participant|
        participants << participant unless participants.include?(participant)
      end
    end

    participants.uniq
  end

  def linked_participants_for_event
    return [] unless event

    participants = matching_participants.joins(:participant_events)
                                        .where(participant_events: { event_id: event_id })
                                        .distinct.to_a

    matching_guardians.includes(guardian_participant_events: [ :participant, :participant_event ]).find_each do |guardian|
      guardian.guardian_participant_events.joins(:participant_event).where(participant_events: { event_id: event_id }).each do |gpe|
        participants << gpe.participant unless participants.include?(gpe.participant)
      end
    end

    participants.uniq
  end
end
