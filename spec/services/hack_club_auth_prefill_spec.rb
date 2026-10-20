require "rails_helper"

RSpec.describe HackClubAuthPrefill do
  let(:invitation) { create(:invitation, email: "invitee@example.com", sent_at: Time.current) }

  def prefill_for(token)
    described_class.from_session({ "invitation_token" => token })
  end

  it "sends what Attend knows about the invitee" do
    create(:participant, email: "Invitee@Example.com", legal_first_name: "Dana", legal_last_name: "Lee",
      date_of_birth: Date.new(2009, 4, 2), phone: "+12025550143", country_of_residence: "United Kingdom")

    expect(prefill_for(invitation.token)).to eq(
      login_hint: "invitee@example.com",
      email: "invitee@example.com",
      first_name: "Dana",
      last_name: "Lee",
      birthday: "2009-04-02",
      phone_number: "+12025550143",
      country: "GB"
    )
  end

  it "leaves out placeholder names and anything missing" do
    create(:participant, email: "invitee@example.com", legal_first_name: "Unknown", legal_last_name: "Unknown",
      date_of_birth: nil, phone: nil, country_of_residence: nil)

    expect(prefill_for(invitation.token)).to eq(login_hint: "invitee@example.com", email: "invitee@example.com")
  end

  it "sends nothing without an open invitation" do
    expect(described_class.from_session({})).to eq({})
    expect(described_class.from_session(nil)).to eq({})
    expect(prefill_for("nope")).to eq({})
    expect(prefill_for(create(:invitation, :accepted).token)).to eq({})
    expect(prefill_for(create(:invitation, :expired).token)).to eq({})
  end
end
