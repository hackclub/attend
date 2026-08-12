require "rails_helper"

RSpec.describe Exports::FieldRegistry do
  describe "FIELDS" do
    it "has unique keys matching each field's key attribute" do
      described_class::FIELDS.each do |key, field|
        expect(field.key).to eq(key)
      end
    end

    it "only uses declared categories" do
      described_class.all.each do |field|
        expect(described_class::CATEGORIES).to have_key(field.category), "unknown category for #{field.key}"
      end
    end

    it "gives every field at least one filter operator unless leg-level" do
      described_class.all.select(&:filterable?).each do |field|
        expect(field.operators).not_to be_empty, "no operators for #{field.key} (type #{field.type})"
      end
    end

    it "defines enum values for every enum field" do
      described_class.all.select { |f| f.type == :enum }.each do |field|
        expect(field.enum_values).to be_present, "missing enum_values for #{field.key}"
      end
    end
  end

  describe ".permitted_keys" do
    it "excludes sensitive categories for ops" do
      keys = described_class.permitted_keys(role: "ops")
      expect(keys).to include("participant.email", "travel.inbound.mode", "participant_event.status")
      expect(keys).not_to include("medical.allergies", "dietary.diet_type", "accommodation.check_in_date",
                                  "safeguarding.high_support_flag", "emergency_contact.1.name")
    end

    it "gives safeguarding leads identity + sensitive categories but not general ones" do
      keys = described_class.permitted_keys(role: "safeguarding_lead")
      expect(keys).to include("participant.email", "participant.full_legal_name",
                              "medical.allergies", "dietary.diet_type", "accommodation.check_in_date")
      expect(keys).not_to include("participant.phone", "travel.inbound.mode", "participant_event.status")
    end

    it "gives event admins everything" do
      expect(described_class.permitted_keys(role: "event_admin").sort).to eq(described_class::FIELDS.keys.sort)
    end

    it "gives global admins everything regardless of role" do
      expect(described_class.permitted_keys(role: nil, global_admin: true).sort).to eq(described_class::FIELDS.keys.sort)
    end

    it "gives read_only users nothing" do
      expect(described_class.permitted_keys(role: "read_only")).to be_empty
    end
  end

  describe "extractors" do
    let(:event) { create(:event) }
    let(:bare_pe) { create(:participant_event, event: event) }

    it "are nil-safe on a participant event with no associated records" do
      described_class.all.each do |field|
        expect {
          field.leg_level? ? field.extractor.call(bare_pe, nil, nil) : field.extractor.call(bare_pe)
        }.not_to raise_error, "extractor for #{field.key} raised on a bare participant event"
      end
    end

    it "extracts values from populated associations" do
      pe = create(:participant_event, :checked_in, event: event, status: "complete")
      pe.create_medical!(has_anaphylaxis_risk: true, medical_conditions: "asthma")
      pe.create_dietary!(diet_type: "vegetarian")
      pe.create_accommodation!(check_in_date: Date.new(2026, 7, 10))
      travel = Travel.create!(participant_event: pe, direction: "inbound", mode: "plane", carrier: "United")
      create(:travel_leg, travel: travel, position: 0, flight_code: "UA100", departure_airport: "SFO", arrival_airport: "BOS")
      EmergencyContact.create!(participant_event: pe, name: "Jane Doe", phone: "+12025550000", priority: 1)

      expect(described_class.fetch("participant_event.status").extractor.call(pe)).to eq("complete")
      expect(described_class.fetch("medical.has_anaphylaxis_risk").extractor.call(pe)).to be(true)
      expect(described_class.fetch("medical.has_medical_conditions").extractor.call(pe)).to be(true)
      expect(described_class.fetch("dietary.diet_type").extractor.call(pe)).to eq("vegetarian")
      expect(described_class.fetch("accommodation.check_in_date").extractor.call(pe)).to eq(Date.new(2026, 7, 10))
      expect(described_class.fetch("travel.inbound.carrier").extractor.call(pe)).to eq("United")
      expect(described_class.fetch("travel.inbound.legs_summary").extractor.call(pe)).to include("UA100", "SFO→BOS")
      expect(described_class.fetch("emergency_contact.1.name").extractor.call(pe)).to eq("Jane Doe")
      expect(described_class.fetch("emergency_contact.2.name").extractor.call(pe)).to be_nil
    end
  end

  describe "PRESETS" do
    it "only references registered fields and valid row modes" do
      described_class::PRESETS.each do |key, preset|
        unknown = preset[:columns] - described_class::FIELDS.keys
        expect(unknown).to be_empty, "preset #{key} has unknown columns: #{unknown}"
        expect(described_class::ROW_MODES).to include(preset[:row_mode])
      end
    end
  end
end
