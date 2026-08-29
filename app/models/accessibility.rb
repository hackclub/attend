class Accessibility < ApplicationRecord
  include ClearsNegativeResponses

  has_paper_trail

  self.implicit_order_column = "created_at"

  encrypts :mobility_needs, :sensory_needs, :communication_needs, :religious_practices, :other_needs

  clears_negative_responses :mobility_needs, :sensory_needs, :communication_needs,
                            :religious_practices, :other_needs, :neurodivergent_notes,
                            :distance_limitations, :unavailable_times

  belongs_to :participant_event
  has_one :participant, through: :participant_event
  has_one :event, through: :participant_event

  validates :participant_event_id, presence: true

  def has_mobility_needs?
    step_free_required? || uses_wheelchair? || mobility_needs.present?
  end

  def has_sensory_needs?
    hearing_impaired? || visually_impaired? || sensory_needs.present?
  end

  def has_communication_needs?
    requires_interpreter? || requires_captions? || communication_needs.present?
  end

  def needs_accommodation?
    has_mobility_needs? || has_sensory_needs? || has_communication_needs? ||
      religious_practices.present? || other_needs.present?
  end
end
