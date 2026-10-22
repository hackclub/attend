# Food risk is split across two records: the health form's Medical
# (allergies, anaphylaxis risk) and the food form's Dietary (life-threatening
# food allergies, cross-contamination, diet type). The participant page and
# the scanner read both through here so neither shows only half and says
# "no flags" when there are some. Only booleans and the diet type: surfaces
# that may show the free text read it from the records themselves.
class FoodSafetySummary
  def initialize(medical:, dietary:)
    @medical = medical
    @dietary = dietary
  end

  def anaphylaxis_risk?
    @medical&.anaphylaxis_risk? || false
  end

  def allergies?
    @medical&.has_allergies? || false
  end

  def life_threatening_food_allergies?
    @dietary&.has_life_threatening_allergy? || false
  end

  def cross_contamination_risk?
    @dietary&.cross_contamination_risk || false
  end

  def diet_type
    @dietary&.diet_type
  end

  def any_flags?
    anaphylaxis_risk? || allergies? || life_threatening_food_allergies? || cross_contamination_risk?
  end
end
