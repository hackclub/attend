require "rails_helper"

RSpec.describe VisaLetterMailer do
  let(:event) { create(:event, name: "Fictional Hackathon", support_email: "fictional@hackclub.com") }
  let(:application) { create(:visa_letter_application, event: event, full_name: "Ada Example", email: "ada@example.com") }

  before { create(:visa_letter_template, :default) }

  it "sends the letter itself, from the event's support address" do
    application.approve!(by: create(:user))
    application.issue_letter!

    mail = described_class.letter_ready(application: application)

    expect(mail.to).to eq([ "ada@example.com" ])
    expect(mail.from).to eq([ "fictional@hackclub.com" ])
    expect(mail.subject).to eq("Your Visa Letter is Ready - Fictional Hackathon")
    expect(mail.attachments.map(&:filename)).to eq([ "visa-letter-#{application.reference_number}.pdf" ])
    [ mail.html_part, mail.text_part ].each do |part|
      expect(part.body.to_s).to include("Hello Ada Example", application.reference_number, "/visas/applications/#{application.id}/letter")
    end
  end

  it "tells a soft-rejected applicant why, and that they can apply again" do
    application.reject!(by: create(:user), reason: "The name doesn't match your passport.")

    mail = described_class.rejected(application: application)

    [ mail.html_part, mail.text_part ].each do |part|
      body = CGI.unescapeHTML(part.body.to_s)
      expect(body).to include("The name doesn't match your passport.")
      expect(body).to include("You Can Reapply", "/visas/#{event.slug}/apply")
    end
  end

  it "doesn't offer a hard-rejected applicant another go" do
    application.reject!(by: create(:user), reason: "Not eligible.", type: :hard)

    expect(described_class.rejected(application: application).text_part.body.to_s).not_to include("You Can Reapply")
  end

  it "confirms a request with a link to follow it up" do
    mail = described_class.received(application: application)

    expect(mail.subject).to eq("Your Visa Letter Application Has Been Submitted - Fictional Hackathon")
    expect(mail.text_part.body.to_s).to include(application.reference_number, "/visas/applications/#{application.id}")
  end

  it "invites someone to apply with a link that carries their invitation" do
    invitation = create(:visa_letter_invitation, event: event, email: "invitee@example.com")

    mail = described_class.invitation_to_apply(invitation: invitation)

    expect(mail.to).to eq([ "invitee@example.com" ])
    expect(mail.text_part.body.to_s).to include("/visas/#{event.slug}/apply?invite=#{invitation.token}")
  end

  it "tells someone whose hard rejection was softened that they can apply again" do
    application.reject!(by: create(:user), reason: "Duplicate", type: :hard)
    application.downgrade_rejection!

    expect(described_class.rejection_downgraded(application: application).text_part.body.to_s).to include("/visas/#{event.slug}/apply")
  end

  it "tells the event's admins about a new request, without the applicant's details" do
    create(:event_role_assignment, event: event, role: "event_admin", user: create(:user, email: "reviewer@example.com"))
    create(:event_role_assignment, event: event, role: "ops", user: create(:user, email: "ops@example.com"))

    mail = described_class.new_application(application: application)

    expect(mail.to).to eq([ "reviewer@example.com" ])
    expect(mail.text_part.body.to_s).not_to include("Ada Example")
  end

  it "sends a new request to the event's support address when it has no admins" do
    expect(described_class.new_application(application: application).to).to eq([ "fictional@hackclub.com" ])
  end
end
