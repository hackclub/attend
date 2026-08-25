class Ticket < ApplicationRecord
  class MergedTicketError < StandardError; end

  include ActionView::RecordIdentifier

  has_paper_trail

  self.implicit_order_column = "created_at"

  belongs_to :event, optional: true
  belongs_to :subject, polymorphic: true, optional: true # Participant or Guardian
  belongs_to :assigned_to, class_name: "User", optional: true
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :closed_by, class_name: "User", optional: true
  belongs_to :merged_into, class_name: "Ticket", optional: true
  belongs_to :merged_by, class_name: "User", optional: true

  has_many :ticket_messages, dependent: :destroy
  has_many :notes, dependent: :nullify
  has_many :merged_tickets, class_name: "Ticket", foreign_key: :merged_into_id,
           inverse_of: :merged_into, dependent: :nullify

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
  # Merged tickets are tombstones: their thread now lives on another ticket, so
  # they stay out of the inbox and out of inbound-message matching.
  scope :unmerged, -> { where(merged_into_id: nil) }

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
    if merged?
      broadcast_remove_to(:tickets_index, target: dom_id(self))
      return
    end

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
    raise MergedTicketError, "This ticket was merged into ##{merged_into_id&.first(8)}" if merged?

    update!(status: :open, closed_at: nil, closed_by: nil)
  end

  def merged?
    merged_into_id.present?
  end

  # Where this ticket's thread actually lives now. Follows a chain of merges and
  # stops on itself if the data ever loops back around.
  def merge_root
    ticket = self
    seen = Set.new([ id ])

    while (parent = ticket.merged_into) && seen.add?(parent.id)
      ticket = parent
    end

    ticket
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
