class SafeguardingInfo < ApplicationRecord
  include WalletPassUpdatable

  has_paper_trail

  self.implicit_order_column = "created_at"

  encrypts :authorized_pickup_adults, :other_instructions, :high_support_notes

  belongs_to :participant_event
  has_one :participant, through: :participant_event
  has_one :event, through: :participant_event

  validates :participant_event_id, presence: true

  before_validation :set_adult_freedom_defaults

  def has_freedom_waiver?
    freedom_waiver_granted
  end

  def requires_supervised_departure?
    !can_leave_unaccompanied
  end

  def high_support?
    high_support_flag
  end

  private

  def participant_events_to_update
    [ participant_event ].compact
  end

  def set_adult_freedom_defaults
    return unless participant_event
    return if participant_event.requires_guardian?

    self.can_leave_unaccompanied = true unless can_leave_unaccompanied
    self.freedom_waiver_granted = true unless freedom_waiver_granted
  end
end
