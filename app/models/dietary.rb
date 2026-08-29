class Dietary < ApplicationRecord
  include ClearsNegativeResponses

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

  def has_life_threatening_allergy?
    life_threatening_allergies.present?
  end

  def dietary_restrictions?
    !omnivore? || intolerances.present?
  end
end
