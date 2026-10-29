require "rails_helper"

RSpec.describe "Admin visa letter invitations", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, visa_letters: "invite_only") }
  let(:admin) { create(:user, admin_console_beta: false).tap { |user| create(:event_role_assignment, user: user, event: event, role: "event_admin") } }

  before { sign_in admin }

  { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
    context ui do
      before { admin.update!(admin_console_beta: console) }

      it "invites people, skipping addresses it can't use" do
        create(:ban, email: "banned-invitee@example.com")

        expect {
          post admin_event_visa_letter_invitations_path(event),
            params: { emails: "first@example.com, Second@Example.com\nnot-an-email\nbanned-invitee@example.com" }
        }.to have_enqueued_mail(VisaLetterMailer, :invitation_to_apply).exactly(2).times

        expect(event.visa_letter_invitations.pluck(:email)).to contain_exactly("first@example.com", "second@example.com")
        expect(flash[:alert]).to include("not-an-email", "banned-invitee@example.com")

        get admin_event_visa_letter_invitations_path(event)
        expect(response.body).to include("first@example.com", "Pending")
      end

      it "sends the same invitation again rather than a second one" do
        invitation = create(:visa_letter_invitation, event: event, email: "again@example.com")

        expect {
          post admin_event_visa_letter_invitations_path(event), params: { emails: "again@example.com" }
        }.not_to change(VisaLetterInvitation, :count)
        expect(VisaLetterInvitation.last).to eq(invitation)
      end

      it "withdraws an unused invitation, but not one that's been used" do
        unused = create(:visa_letter_invitation, event: event)
        used = create(:visa_letter_invitation, event: event).tap(&:claim!)

        delete admin_event_visa_letter_invitation_path(event, unused)
        delete admin_event_visa_letter_invitation_path(event, used)

        expect(VisaLetterInvitation.exists?(unused.id)).to be(false)
        expect(VisaLetterInvitation.exists?(used.id)).to be(true)
      end
    end
  end

  it "is for the event's admins" do
    sign_in create(:user).tap { |user| create(:event_role_assignment, user: user, event: event, role: "ops") }

    post admin_event_visa_letter_invitations_path(event), params: { emails: "someone@example.com" }

    expect(VisaLetterInvitation.count).to eq(0)
  end
end
