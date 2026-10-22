require "rails_helper"

RSpec.describe FoodSafetySummary do
  def summary(medical: nil, dietary: nil)
    described_class.new(medical: medical, dietary: dietary)
  end

  it "has no flags and no diet type when neither record exists" do
    s = summary

    expect(s.anaphylaxis_risk?).to be(false)
    expect(s.allergies?).to be(false)
    expect(s.life_threatening_food_allergies?).to be(false)
    expect(s.cross_contamination_risk?).to be(false)
    expect(s.diet_type).to be_nil
    expect(s.any_flags?).to be(false)
  end

  it "has no flags for empty records" do
    expect(summary(medical: Medical.new, dietary: Dietary.new).any_flags?).to be(false)
  end

  it "flags the dietary allergy fields when the medical record says nothing" do
    s = summary(medical: Medical.new, dietary: Dietary.new(life_threatening_allergies: "Peanuts", cross_contamination_risk: true, diet_type: "vegan"))

    expect(s.life_threatening_food_allergies?).to be(true)
    expect(s.cross_contamination_risk?).to be(true)
    expect(s.diet_type).to eq("vegan")
    expect(s.anaphylaxis_risk?).to be(false)
    expect(s.allergies?).to be(false)
    expect(s.any_flags?).to be(true)
  end

  it "flags the medical allergy fields without a dietary record" do
    s = summary(medical: Medical.new(allergies: "Penicillin", has_anaphylaxis_risk: true))

    expect(s.anaphylaxis_risk?).to be(true)
    expect(s.allergies?).to be(true)
    expect(s.life_threatening_food_allergies?).to be(false)
    expect(s.any_flags?).to be(true)
  end

  it "counts each flag on its own towards any_flags?" do
    expect(summary(medical: Medical.new(has_anaphylaxis_risk: true)).any_flags?).to be(true)
    expect(summary(medical: Medical.new(allergies: "Latex")).any_flags?).to be(true)
    expect(summary(dietary: Dietary.new(life_threatening_allergies: "Shellfish")).any_flags?).to be(true)
    expect(summary(dietary: Dietary.new(cross_contamination_risk: true)).any_flags?).to be(true)
  end

  it "doesn't count a diet type as a flag" do
    expect(summary(dietary: Dietary.new(diet_type: "halal")).any_flags?).to be(false)
  end

  it "is built from a participant event's records" do
    pe = create(:participant_event)
    pe.create_dietary!(cross_contamination_risk: true)

    expect(pe.food_safety_summary.cross_contamination_risk?).to be(true)
    expect(pe.food_safety_summary.anaphylaxis_risk?).to be(false)
  end
end
