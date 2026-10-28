# One person on an eligible-only stay's roster. Being on the roster is what
# puts them in that stay's rooming pool; taking them off also gives up any
# room they had in it.
class RoomingRosterEntry < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :rooming_context
  belongs_to :participant_event
  belongs_to :eligibility_option, class_name: "RoomingEligibilityOption", foreign_key: :rooming_eligibility_option_id, optional: true
  belongs_to :added_by_user, class_name: "User", optional: true

  enum :source, {
    manual: "manual",
    csv: "csv",
    group: "group",
    api: "api"
  }, prefix: true

  validates :participant_event_id, uniqueness: { scope: :rooming_context_id, message: "is already on this stay's list" }
  validate :same_event
  validate :option_belongs_to_stay
  validate :stay_takes_a_roster

  after_destroy :release_room

  private

  def same_event
    return unless rooming_context && participant_event

    errors.add(:participant_event, "isn't registered for this event") if participant_event.event_id != rooming_context.event_id
  end

  def option_belongs_to_stay
    return unless eligibility_option && rooming_context

    errors.add(:eligibility_option, "isn't one of this stay's options") if eligibility_option.rooming_context_id != rooming_context_id
  end

  def stay_takes_a_roster
    return unless rooming_context&.everyone?

    errors.add(:rooming_context, "already includes everyone, so it has no list")
  end

  def release_room
    RoomAssignment.where(rooming_context_id: rooming_context_id, participant_event_id: participant_event_id).destroy_all
  end
end
