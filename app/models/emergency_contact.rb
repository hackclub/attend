class EmergencyContact < ApplicationRecord
  include NormalizesPhoneNumbers
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
  validates :phone, presence: true, e164_phone: true
  validate :linked_to_guardian_or_participant

  normalizes_phone_number :phone

  scope :by_priority, -> { order(priority: :asc) }

  def participant
    participant_event&.participant || guardian_participant_event&.participant
  end

  # `name` is one free-form field, so the first word is the best we can do for a
  # first name. Roles that can't see contact details still get this much plus
  # the phone number, so they can call the contact during an incident.
  def first_name
    name.to_s.split.first.presence || name
  end

  private

  def linked_to_guardian_or_participant
    if guardian_participant_event_id.blank? && participant_event_id.blank?
      errors.add(:base, "Emergency contact must belong to a guardian or a participant.")
    end
  end
end
