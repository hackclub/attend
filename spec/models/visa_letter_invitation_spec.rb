require "rails_helper"

RSpec.describe VisaLetterInvitation do
  include ActiveSupport::Testing::TimeHelpers

  it "normalizes the email and issues a token" do
    invitation = create(:visa_letter_invitation, email: " Invitee@Example.com ")

    expect(invitation.email).to eq("invitee@example.com")
    expect(invitation.token).to be_present
    expect(described_class.for_email("INVITEE@example.com")).to contain_exactly(invitation)
  end

  it "won't invite a banned address" do
    create(:ban, email: "banned-invitee@example.com")

    invitation = build(:visa_letter_invitation, email: "banned-invitee@example.com")
    expect(invitation).not_to be_valid
    expect(invitation.errors[:email]).to include("is banned from events")
  end

  it "records when it's claimed, once" do
    invitation = create(:visa_letter_invitation)

    invitation.claim!
    first_claim = invitation.claimed_at
    travel 1.hour do
      invitation.claim!
    end

    expect(invitation.reload.claimed_at).to be_within(1.second).of(first_claim)
    expect(described_class.unclaimed).not_to include(invitation)
  end
end
