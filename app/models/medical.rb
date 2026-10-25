class Medical < ApplicationRecord
  include ClearsNegativeResponses
  include HealthSectionResponse

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

  def has_allergies?
    ClearsNegativeResponses.meaningful_response?(allergies)
  end

  def anaphylaxis_risk?
    has_anaphylaxis_risk
  end

  def needs_medication_storage?
    requires_refrigeration
  end

  def health_section_has_details?
    [ allergies, allergy_severity, medical_conditions, medications,
      emergency_action_plan, additional_notes ].any?(&:present?) ||
      has_anaphylaxis_risk? || requires_refrigeration?
  end

  private

  def set_last_updated_by
    self.last_updated_by = Current.user if Current.user
  end
end
