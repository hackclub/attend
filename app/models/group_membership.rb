class GroupMembership < ApplicationRecord
  include TravelCalendarCacheInvalidatable

  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :group
  belongs_to :participant_event

  validates :group_id, uniqueness: { scope: :participant_event_id }
  validate :same_event

  private

  def travel_calendar_event_ids
    participant_event_ids = [ participant_event_id, saved_change_to_participant_event_id&.first ].compact
    ParticipantEvent.where(id: participant_event_ids).distinct.pluck(:event_id)
  end

  def same_event
    return unless group && participant_event
    return if group.event_id == participant_event.event_id

    errors.add(:base, "group and participant must belong to the same event")
  end
end
