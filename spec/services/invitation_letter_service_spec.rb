require "rails_helper"

RSpec.describe InvitationLetterService do
  include ActiveSupport::Testing::TimeHelpers

  let(:event) do
    create(:event, name: "Fictional Hackathon", venue_name: "Example Hall", location_address: "1 Example Street",
      location_city: "Burlington", location_country: "United States", timezone: "Eastern Time (US & Canada)",
      starts_at: Time.utc(2027, 5, 7, 16), ends_at: Time.utc(2027, 5, 9, 22), support_email: "fictional@hackclub.com")
  end
  let(:participant) { create(:participant, legal_first_name: "Ada", legal_last_name: "Example", date_of_birth: Date.new(2009, 1, 4)) }
  let(:registration) { create(:participant_event, participant: participant, event: event) }

  def letter
    letter_text(described_class.new(registration).generate)
  end

  it "says who invited them, to what, when and where, that they won't work, and that they'll go home" do
    text = travel_to(Time.utc(2026, 10, 30, 12)) { letter }

    expect(text).to include("October 30, 2026", "To the Border Services Officer,",
      "has invited Ada Example, born January 4, 2009, to attend Fictional Hackathon, taking place from May 7, 2027 to May 9, 2027 " \
        "at Example Hall, 1 Example Street, Burlington, United States.",
      "They will not be employed, paid or doing any business during their visit.",
      "We expect Ada to leave the country when the event ends on May 9, 2027 and return home.",
      "please contact us at fictional@hackclub.com or +1 (855) 625-4225.", "Zach Latta")
    expect(text).not_to include("under 18")
  end

  it "says what Hack Club covers only when the event's staff have written it" do
    expect(letter).not_to include("Hack Club provides")

    event.update!(invitation_letter_costs: "Hack Club provides accommodation & meals during the event.")
    expect(letter).to include("Hack Club provides accommodation & meals during the event.")
  end

  context "for someone under 18 at the event" do
    let(:participant) { create(:participant, legal_first_name: "Ada", legal_last_name: "Example", date_of_birth: Date.new(2011, 6, 1)) }
    let(:guardian_registration) do
      create(:guardian_participant_event, participant_event: registration, guardian: create(:guardian, legal_first_name: "Grace", legal_last_name: "Example"))
    end

    it "names their guardian only once that guardian has signed for them" do
      consent = create(:consent, participant_event: registration, guardian_participant_event: guardian_registration)
      expect(letter).not_to include("under 18")

      consent.update!(status: :signed, signed_at: Time.current, guardian_signed_at: Time.current)
      expect(letter).to include("Ada is under 18. Their parent or guardian, Grace Example, has given written consent for them to attend")
    end
  end
end
