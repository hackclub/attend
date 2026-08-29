class Medical < ApplicationRecord
  include ClearsNegativeResponses

  has_paper_trail

  self.implicit_order_column = "created_at"

  encrypts :allergies, :medical_conditions, :medications, :emergency_action_plan, :additional_notes

  clears_negative_responses :allergies, :medical_conditions, :medications,
                            :emergency_action_plan, :additional_notes

  belongs_to :participant_event
  belongs_to :last_updated_by, class_name: "User", foreign_key: "last_updated_by_user_id", optional: true
  has_one :participant, through: :participant_event
  has_one :event, through: :participant_event

  validates :participant_event_id, presence: true

  before_save :set_last_updated_by

  NEGATIVE_RESPONSES = %w[none no n/a na nil null nothing nope - 0].freeze

  def has_allergies?
    return false if allergies.blank?

    normalized = allergies.strip.downcase
    !NEGATIVE_RESPONSES.include?(normalized)
  end

  def anaphylaxis_risk?
    has_anaphylaxis_risk
  end

  def needs_medication_storage?
    requires_refrigeration
  end

  private

  def set_last_updated_by
    self.last_updated_by = Current.user if Current.user
  end
end
