require "rails_helper"

RSpec.describe ClearsNegativeResponses do
  let(:participant_event) { create(:participant_event) }
  let(:medical) { Medical.new(participant_event: participant_event) }

  describe "answers that mean nothing" do
    [ "NO", "No", "none", "None", "N/A", "n/a", "NA", "na", "  None  ", "None." ].each do |answer|
      it "clears #{answer.inspect}" do
        medical.allergies = answer

        expect(medical.allergies).to be_nil
      end
    end
  end

  describe "answers that mean something" do
    [ "No known allergies", "none that need refrigeration", "Peanuts", "Nasal spray" ].each do |answer|
      it "keeps #{answer.inspect}" do
        medical.allergies = answer

        expect(medical.allergies).to eq(answer)
      end
    end

    it "keeps ambiguous single characters rather than guessing" do
      medical.allergies = "-"

      expect(medical.allergies).to eq("-")
    end

    it "strips surrounding whitespace from a real answer" do
      medical.allergies = "  Penicillin  "

      expect(medical.allergies).to eq("Penicillin")
    end
  end

  it "clears every free-text field on the medical form" do
    medical.update!(
      allergies: "none", medical_conditions: "N/A", medications: "No",
      emergency_action_plan: "na", additional_notes: "None."
    )
    dietary = Dietary.create!(
      participant_event: participant_event,
      intolerances: "none", life_threatening_allergies: "N/A", notes: "NA"
    )
    accessibility = Accessibility.create!(
      participant_event: participant_event,
      mobility_needs: "none", sensory_needs: "N/A", communication_needs: "No",
      religious_practices: "na", other_needs: "None.", neurodivergent_notes: "none",
      distance_limitations: "N/A", unavailable_times: "NA"
    )

    expect(medical.reload.attributes.values_at(
      "allergies", "medical_conditions", "medications", "emergency_action_plan", "additional_notes"
    )).to all(be_nil)
    expect(dietary.reload.attributes.values_at(
      "intolerances", "life_threatening_allergies", "notes"
    )).to all(be_nil)
    expect(accessibility.reload.attributes.values_at(
      "mobility_needs", "sensory_needs", "communication_needs", "religious_practices",
      "other_needs", "neurodivergent_notes", "distance_limitations", "unavailable_times"
    )).to all(be_nil)
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
