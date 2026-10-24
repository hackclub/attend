class Dietary < ApplicationRecord
  include ClearsNegativeResponses
  include HealthSectionResponse

  has_paper_trail

  self.implicit_order_column = "created_at"

  encrypts :intolerances, :life_threatening_allergies, :notes

  clears_negative_responses :intolerances, :life_threatening_allergies, :notes

  belongs_to :participant_event
  has_one :participant, through: :participant_event
  has_one :event, through: :participant_event

  enum :diet_type, {
    omnivore: "omnivore",
    vegetarian: "vegetarian",
    vegan: "vegan",
    halal: "halal",
    kosher: "kosher",
    other: "other"
  }

  validates :participant_event_id, presence: true

  # "None" and "no" survive ClearsNegativeResponses, so read them the way
  # Medical#has_allergies? does rather than as an allergy.
  def has_life_threatening_allergy?
    return false if life_threatening_allergies.blank?

    !Medical::NEGATIVE_RESPONSES.include?(life_threatening_allergies.strip.downcase)
  end

  def dietary_restrictions?
    !omnivore? || intolerances.present?
  end

  def health_section_has_details?
    [ diet_type, intolerances, life_threatening_allergies, notes ].any?(&:present?) ||
      cross_contamination_risk?
  end
end
