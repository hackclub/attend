class Scan < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :participant_event
  belongs_to :user
  belongs_to :scan_context

  has_one :participant, through: :participant_event
  has_one :event, through: :participant_event

  validates :scanned_at, presence: true
  validates :client_scan_id, uniqueness: true, allow_nil: true

  scope :recent, -> { order(scanned_at: :desc) }
  scope :for_event, ->(event) { joins(:participant_event).where(participant_events: { event_id: event.id }) }
  scope :today, -> { where(scanned_at: Time.current.beginning_of_day..Time.current.end_of_day) }
  scope :for_check_in, -> { joins(:scan_context).where(scan_contexts: { checks_in: true }) }
  scope :for_airport, -> { joins(:scan_context).where(scan_contexts: { is_travel_pickup: true }) }
  scope :for_airport_or_check_in, -> { joins(:scan_context).where(scan_contexts: { is_travel_pickup: true }).or(joins(:scan_context).where(scan_contexts: { checks_in: true })) }
  scope :for_context, ->(context) { where(scan_context: context) }

  after_create_commit :broadcast_scan

  private

  def broadcast_scan
    medical = participant_event.medical

    ActionCable.server.broadcast(
      "event_scans_#{event.id}",
      {
        scan_id: id,
        scanned_at: scanned_at.iso8601,
        scanned_by: user.name,
        participant: {
          id: participant.id,
          display_name: participant.display_name,
          full_name: participant.full_name,
          status: participant_event.status,
          has_anaphylaxis_risk: medical&.has_anaphylaxis_risk || false
        }
      }
    )
  end
end
