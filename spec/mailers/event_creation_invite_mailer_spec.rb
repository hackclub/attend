require "rails_helper"

RSpec.describe EventCreationInviteMailer, type: :mailer do
  let(:inviter) { create(:user, email: "boss@example.com", name: "The Boss") }
  let(:series) { create(:event_series, name: "Summit Series") }
  let(:invite) { create(:event_creation_invite, email: "organizer@example.com", invited_by: inviter, event_series: series, note: "Dates are up to you.") }

  it "sends a working link to the invited address" do
    mail = described_class.invite(invite)

    expect(mail.to).to eq([ "organizer@example.com" ])
    expect(mail.reply_to).to eq([ "boss@example.com" ])
    expect(mail.subject).to eq("Set up your event on Attend")

    body = mail.text_part.body.decoded
    expect(body).to include("The Boss", "Summit Series", "Dates are up to you.")
    token = body[%r{/event-invites/(\S+)}, 1]
    expect(EventCreationInvite.find_by_token(token)).to eq(invite)
    expect(invite.reload.last_sent_at).to be_present
  end
end
