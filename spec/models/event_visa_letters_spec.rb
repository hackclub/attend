require "rails_helper"

RSpec.describe Event, "visa letters" do
  include ActiveSupport::Testing::TimeHelpers

  let(:event) { create(:event, timezone: "Pacific Time (US & Canada)") }

  it "is off unless set to one of the modes" do
    expect(event.visa_letters_mode).to eq("off")
    expect(event).not_to be_visa_letters_enabled

    event.visa_letters = "sometimes"
    expect(event).not_to be_valid
    expect(event.visa_letters_mode).to eq("off")
  end

  it "takes public applications only in open mode, until the deadline on the event's clock" do
    event.update!(visa_letters: "invite_only")
    expect(event).to be_visa_letters_enabled
    expect(event).not_to be_accepting_visa_letter_applications

    event.update!(visa_letters: "open", visa_letter_deadline: "2027-01-31")
    travel_to Time.utc(2027, 2, 1, 7, 59) do # still the 31st in California
      expect(event).to be_accepting_visa_letter_applications
    end
    travel_to Time.utc(2027, 2, 1, 8, 1) do
      expect(event).not_to be_accepting_visa_letter_applications
    end
  end

  it "rejects a deadline that isn't a date" do
    event.visa_letter_deadline = "next friday"

    expect(event).not_to be_valid
    expect(event.errors[:visa_letter_deadline]).to include("must be a date")
  end

  it "can't be deleted once it has issued letters" do
    create(:visa_letter_application, event: event)

    expect(event.destroy).to be(false)
    expect(event.errors[:base].join).to match(/visa letter applications/)
  end
end
