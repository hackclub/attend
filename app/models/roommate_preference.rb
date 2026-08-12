class RoommatePreference < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :participant_event
  belongs_to :preferred_participant_event, class_name: "ParticipantEvent"

  has_one :participant, through: :participant_event
  has_one :preferred_participant, through: :preferred_participant_event, source: :participant

  validates :participant_event_id, uniqueness: { scope: :preferred_participant_event_id }
  validate :not_self_preference

  scope :ranked, -> { order(:rank) }
  scope :confirmed, -> { where(admin_confirmed: true) }
  scope :mutual, -> {
    joins("INNER JOIN roommate_preferences rp2 ON roommate_preferences.participant_event_id = rp2.preferred_participant_event_id AND roommate_preferences.preferred_participant_event_id = rp2.participant_event_id")
  }

  def mutual?
    RoommatePreference.exists?(
      participant_event_id: preferred_participant_event_id,
      preferred_participant_event_id: participant_event_id
    )
  end

  private

  def not_self_preference
    if participant_event_id == preferred_participant_event_id
      errors.add(:preferred_participant_event_id, "cannot prefer yourself as a roommate")
    end
  end
end
