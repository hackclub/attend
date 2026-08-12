class EmergencyContact < ApplicationRecord
  has_paper_trail

  self.implicit_order_column = "created_at"

  # `phone` is encrypted deterministically so it can still be looked up by
  # equality if needed in the future (mirrors Participant). `name` is
  # non-deterministic since it is free-form and not queried by value.
  encrypts :name
  encrypts :phone, deterministic: true

  belongs_to :guardian_participant_event, optional: true
  belongs_to :participant_event, optional: true

  has_one :guardian, through: :guardian_participant_event

  validates :name, presence: true
  validates :phone, presence: true, phone: { possible: true }
  validate :linked_to_guardian_or_participant

  before_validation :normalize_phone

  scope :by_priority, -> { order(priority: :asc) }

  def participant
    participant_event&.participant || guardian_participant_event&.participant
  end

  private

  def normalize_phone
    return if phone.blank?

    parsed = Phonelib.parse(phone)
    self.phone = parsed.e164 if parsed.valid?
  end

  def linked_to_guardian_or_participant
    if guardian_participant_event_id.blank? && participant_event_id.blank?
      errors.add(:base, "Emergency contact must belong to a guardian or a participant.")
    end
  end
end
