require "rails_helper"

RSpec.describe Incident, type: :model do
  let(:event) { create(:event) }
  let(:reporter) { create(:user) }
  let(:staff) { create(:user) }
  let(:participant_event) { create(:participant_event, event: event) }

  def build_incident(**attrs)
    event.incidents.build(reported_by: reporter, category: "medical", severity: "s3", **attrs)
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
      expect(event.incidents.build(reported_by: reporter, category: "behavior", severity: "s3")).to be_valid
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

  describe "occurred_at on the event's clock" do
    let(:event) { create(:event, timezone: "Eastern Time (US & Canada)") }

    def log_incident(**attrs)
      event.incidents.create!(reported_by: reporter, category: "behavior", severity: "s3", **attrs)
    end

    it "reads a typed time in the event's time zone" do
      incident = log_incident(occurred_at: "2026-07-12T09:30")

      expect(incident.occurred_at).to eq(Time.utc(2026, 7, 12, 13, 30))
      expect(incident.times_in_event_zone).to be(true)
      expect(incident.local_time(:occurred_at).strftime("%H:%M %Z")).to eq("09:30 EDT")
      expect(incident.local_time_field_value(:occurred_at)).to eq("2026-07-12T09:30")
    end

    it "leaves a time that names its own offset alone" do
      expect(log_incident(occurred_at: "2026-07-12T09:30:00Z").occurred_at).to eq(Time.utc(2026, 7, 12, 9, 30))
    end

    context "on a row saved before times were read on the event's clock" do
      let(:incident) do
        log_incident.tap do |i|
          i.update_columns(occurred_at: Time.utc(2026, 7, 12, 9, 30), times_in_event_zone: false)
        end.reload
      end

      it "keeps showing and prefilling the time on UTC" do
        expect(incident.time_display_zone.name).to eq("UTC")
        expect(incident.local_time(:occurred_at).strftime("%H:%M %Z")).to eq("09:30 UTC")
        expect(incident.local_time_field_value(:occurred_at)).to eq("2026-07-12T09:30")
      end

      it "stays on UTC through edits that leave the time alone" do
        incident.update!(status: "closed")

        expect(incident.reload.times_in_event_zone).to be(false)
        expect(incident.occurred_at).to eq(Time.utc(2026, 7, 12, 9, 30))
      end

      it "moves onto the event's clock when the form saves its time again" do
        incident.update!(occurred_at: incident.local_time_field_value(:occurred_at))

        incident.reload
        expect(incident.times_in_event_zone).to be(true)
        expect(incident.occurred_at).to eq(Time.utc(2026, 7, 12, 13, 30))
        expect(incident.local_time(:occurred_at).strftime("%H:%M %Z")).to eq("09:30 EDT")
      end
    end
  end
end
