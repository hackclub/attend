require "rails_helper"

RSpec.describe Mcp::ResponseFilter do
  describe ".initials" do
    it "reduces a name to initials" do
      expect(described_class.initials("Leo Wilkin")).to eq("L.W.")
      expect(described_class.initials("Leo")).to eq("L.")
      expect(described_class.initials("mary-jane watson")).to eq("M.J.W.")
    end

    it "is idempotent, because a name can pass through twice" do
      expect(described_class.initials("L.W.")).to eq("L.W.")
    end

    it "leaves nil and blank alone" do
      expect(described_class.initials(nil)).to be_nil
      expect(described_class.initials("")).to eq("")
    end

    it "redacts a value with no letters to initial rather than echoing it" do
      expect(described_class.initials("+1 415 555 0100")).to eq("[redacted]")
    end
  end

  describe ".call" do
    it "reduces person-name keys to initials and leaves other names alone" do
      result = described_class.call({
        name: "Room 214",
        legal_name: "Leo Wilkin",
        author: "Sam Poder",
        assigned_to: "Zach Latta"
      })

      expect(result[:name]).to eq("Room 214")
      expect(result[:legal_name]).to eq("L.W.")
      expect(result[:author]).to eq("S.P.")
      expect(result[:assigned_to]).to eq("Z.L.")
    end

    it "redacts contact and location detail whatever its type" do
      result = described_class.call({
        email: "leo@hackclub.com",
        phone: "+1 415 555 0100",
        date_of_birth: Date.new(2008, 3, 1),
        city: "Burlington",
        slack_user_id: "U123",
        country_of_residence: "United States"
      })

      expect(result.values_at(:email, :phone, :date_of_birth, :city, :slack_user_id))
        .to all(eq("[redacted]"))
      expect(result[:country_of_residence]).to eq("United States")
    end

    it "keeps nils as nils rather than claiming something was redacted" do
      expect(described_class.call({ email: nil })).to eq({ email: nil })
    end

    it "scrubs contact details out of free text" do
      result = described_class.call({
        body: "Ring the guardian on +1 (555) 010-9182 or email kim@example.com today"
      })

      expect(result[:body]).to eq("Ring the guardian on [redacted] or email [redacted] today")
    end

    it "leaves flight codes and ids in free text alone" do
      result = described_class.call({ notes: "On AA1234 arriving 14:05, seat 12F" })

      expect(result[:notes]).to eq("On AA1234 arriving 14:05, seat 12F")
    end

    it "walks nested hashes and arrays" do
      result = described_class.call({
        registrations: [
          { participant_name: "Leo Wilkin", email: "leo@hackclub.com" },
          { participant_name: "Kim Doe", contacts: { phone: "5550100" } }
        ],
        staff_names: [ "Leo Wilkin", "Kim Doe" ]
      })

      expect(result[:registrations].first[:participant_name]).to eq("L.W.")
      expect(result[:registrations].first[:email]).to eq("[redacted]")
      expect(result[:registrations].second[:contacts][:phone]).to eq("[redacted]")
      expect(result[:staff_names]).to eq([ "L.W.", "K.D." ])
    end

    it "leaves times, numbers and booleans intact" do
      at = Time.zone.parse("2026-08-24 10:00")
      result = described_class.call({ at: at, count: 3, checked_in: true })

      expect(result).to eq({ at: at, count: 3, checked_in: true })
    end
  end
end
