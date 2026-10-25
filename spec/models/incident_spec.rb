require "rails_helper"

RSpec.describe Incident, type: :model do
  let(:event) { create(:event) }
  let(:reporter) { create(:user) }
  let(:staff) { create(:user) }
  let(:participant_event) { create(:participant_event, event: event) }

  def build_incident(**attrs)
    event.incidents.build(reported_by: reporter, category: "medical", severity: "low", **attrs)
  end

  describe "medical incidents" do
    it "requires a linked participant" do
      incident = build_incident(helping_staff: [ staff ])

      expect(incident).not_to be_valid
      expect(incident.errors[:base]).to include("Medical incidents must be linked to at least one participant")
    end

    it "requires a linked staff member" do
      incident = build_incident(participant_events: [ participant_event ])

      expect(incident).not_to be_valid
      expect(incident.errors[:base]).to include("Medical incidents must be linked to at least one staff member")
    end

    it "is valid with a participant and a staff member" do
      expect(build_incident(participant_events: [ participant_event ], helping_staff: [ staff ])).to be_valid
    end

    it "requires a medication when one was dispensed" do
      incident = build_incident(participant_events: [ participant_event ], helping_staff: [ staff ], medication_dispensed: true)

      expect(incident).not_to be_valid
      expect(incident.errors[:base]).to include("Add the medication that was dispensed")
    end

    it "saves dispensed medications" do
      incident = build_incident(
        participant_events: [ participant_event ], helping_staff: [ staff ], medication_dispensed: true,
        medications_attributes: [ { name: "Paracetamol", dose: "2 x 500mg", notes: "With water" }, { name: "", dose: "", notes: "" } ]
      )

      expect(incident.save).to be(true)
      expect(incident.medications.reload.map { |m| [ m.name, m.dose, m.notes ] }).to eq([ [ "Paracetamol", "2 x 500mg", "With water" ] ])
    end

    it "drops medications when none were dispensed" do
      incident = build_incident(
        participant_events: [ participant_event ], helping_staff: [ staff ], medication_dispensed: false,
        medications_attributes: [ { name: "Paracetamol", dose: "2 x 500mg" } ]
      )

      expect(incident.save).to be(true)
      expect(incident.medications.reload).to be_empty
    end
  end

  describe "non-medical incidents" do
    it "does not require a participant or staff member" do
      expect(event.incidents.build(reported_by: reporter, category: "behavior", severity: "low")).to be_valid
    end

    it "clears medications left over from a medical category" do
      incident = build_incident(
        participant_events: [ participant_event ], helping_staff: [ staff ], medication_dispensed: true,
        medications_attributes: [ { name: "Ibuprofen", dose: "200mg" } ]
      )
      incident.save!

      incident.update!(category: "other")

      expect(incident.reload.medication_dispensed).to be(false)
      expect(incident.medications).to be_empty
    end
  end
end
