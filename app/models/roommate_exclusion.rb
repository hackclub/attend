class RoommateExclusion < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :participant_event
  belongs_to :excluded_participant_event, class_name: "ParticipantEvent"

  has_one :participant, through: :participant_event
  has_one :excluded_participant, through: :excluded_participant_event, source: :participant

  validates :participant_event_id, uniqueness: { scope: :excluded_participant_event_id }
  validate :not_self_exclusion

  scope :confirmed, -> { where(admin_confirmed: true) }

  def mutual?
    RoommateExclusion.exists?(
      participant_event_id: excluded_participant_event_id,
      excluded_participant_event_id: participant_event_id
    )
  end

  private

  def not_self_exclusion
    if participant_event_id == excluded_participant_event_id
      errors.add(:excluded_participant_event_id, "cannot exclude yourself")
    end
  end
end
