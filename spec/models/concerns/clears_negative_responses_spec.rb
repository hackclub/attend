require "rails_helper"

RSpec.describe ClearsNegativeResponses do
  let(:participant_event) { create(:participant_event) }
  let(:medical) { Medical.new(participant_event: participant_event) }

  describe "answers that mean nothing" do
    [ "N/A", "n/a", "NA", "na", "Not Applicable", " not applicable ", "  N/A  " ].each do |answer|
      it "clears #{answer.inspect}" do
        medical.allergies = answer

        expect(medical.allergies).to be_nil
      end
    end
  end

  describe "answers that mean something" do
    [ "No", "none", "nil", "-", "n/a.", "No known allergies", "none that need refrigeration", "Peanuts", "Nasal spray" ].each do |answer|
      it "keeps #{answer.inspect}" do
        medical.allergies = answer

        expect(medical.allergies).to eq(answer)
      end
    end

    it "keeps a meaningful sentence verbatim" do
      answer = "n/a for medication, but i need step-free access"
      medical.allergies = answer

      expect(medical.allergies).to eq(answer)
    end
  end

  it "clears every free-text field on the medical form" do
    medical.update!(
      allergies: "n/a", medical_conditions: "Not Applicable", medications: "NA",
      emergency_action_plan: "na", additional_notes: " N/A "
    )
    dietary = Dietary.create!(
      participant_event: participant_event,
      intolerances: "not applicable", life_threatening_allergies: "N/A", notes: "NA"
    )
    accessibility = Accessibility.create!(
      participant_event: participant_event,
      mobility_needs: "not applicable", sensory_needs: "N/A", communication_needs: "No",
      religious_practices: "na", other_needs: "None.", neurodivergent_notes: "none",
      distance_limitations: "N/A", unavailable_times: "NA"
    )

    expect(medical.reload.attributes.values_at(
      "allergies", "medical_conditions", "medications", "emergency_action_plan", "additional_notes"
    )).to all(be_nil)
    expect(dietary.reload.attributes.values_at(
      "intolerances", "life_threatening_allergies", "notes"
    )).to all(be_nil)
    accessibility.reload
    expect(accessibility.attributes.values_at(
      "mobility_needs", "sensory_needs", "communication_needs", "religious_practices",
      "other_needs", "neurodivergent_notes", "distance_limitations", "unavailable_times"
    )).to eq([ nil, nil, "No", nil, "None.", "none", nil, nil ])
  end

  it "leaves text already in the database alone until the record is saved again" do
    medical.save!
    # Skip past the normalizer to the encryption type underneath, so the row
    # holds what a row written before this concern existed would hold.
    legacy = Medical.type_for_attribute(:allergies).cast_type.serialize("none")
    Medical.where(id: medical.id).update_all(Medical.sanitize_sql([ "allergies = ?", legacy ]))

    expect(medical.reload.allergies).to eq("none")
    expect(medical.has_allergies?).to be(false)
  end
end
