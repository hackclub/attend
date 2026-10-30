require "rails_helper"

RSpec.describe SchoolExcuseLetterService do
  include ActiveSupport::Testing::TimeHelpers

  let(:event) do
    create(:event, name: "Fictional Hackathon", location_city: "Burlington", location_country: "United States",
      timezone: "Eastern Time (US & Canada)", starts_at: Time.utc(2027, 5, 7, 16), ends_at: Time.utc(2027, 5, 9, 22),
      support_email: "fictional@hackclub.com")
  end
  let(:participant) { create(:participant, legal_first_name: "Ada", legal_last_name: "Example") }
  let(:registration) { create(:participant_event, participant: participant, event: event) }

  it "prints a dated, signed letter on the Hack Foundation's letterhead, on one page" do
    pdf = travel_to(Time.utc(2026, 10, 30, 12)) { described_class.new(registration).generate }
    text = letter_text(pdf)
    reader = PDF::Reader.new(StringIO.new(pdf))

    expect(reader.page_count).to eq(1)
    expect(text).to include("October 30, 2026", "please excuse Ada Example from your institution",
      "attending Hack Club's Fictional Hackathon hackathon in Burlington, United States", "fictional@hackclub.com",
      "Sincerely,", "Zach Latta", "Executive Director", "D.B.A Hack Club")
    expect(text.delete(" ")).to include("ADAEXAMPLE•FICTIONALHACKATHON")
    expect(reader.pages.first.xobjects.size).to eq(2) # the wordmark and the signature
  end

  it "doesn't let a name read as Prawn's formatting tags" do
    participant.update_columns(legal_last_name: "Example <i>Smith</i> & Co")

    expect(letter_text(described_class.new(registration).generate)).to include("Ada Example <i>Smith</i> & Co")
  end
end
