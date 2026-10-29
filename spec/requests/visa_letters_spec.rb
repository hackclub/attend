require "rails_helper"

RSpec.describe "Asking for a visa letter", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, name: "Fictional Hackathon", visa_letters: "open") }
  let(:applicant) do
    create(:user, email: "ada@example.com", hack_club_account_id: "ident!ada",
      oidc_claims: { "legal_first_name" => "Ada", "legal_last_name" => "Example", "birthdate" => "2008-04-01",
                     "phone_number" => "+12025550123", "address" => { "line_1" => "2 Sample Road", "city" => "Example City", "country" => "GB" } })
  end
  let(:details) do
    { full_name: "Ada Example", date_of_birth: "2008-04-01", nationality: "United Kingdom",
      place_of_birth: "Example City", phone: "+12025550123", address: "2 Sample Road\nExample City" }
  end

  before { create(:visa_letter_template, :default) }

  def apply(params = {})
    post visas_apply_path(event.slug, **params), params: { visa_letter_application: details }
  end

  it "asks a signed-out visitor to sign in first, and comes back to the form afterwards" do
    get visas_apply_path(event.slug)

    expect(response).to have_http_status(:unauthorized)
    expect(response.body).to include("Apply for Visa Letter", "Fictional Hackathon")
    expect(session["user_return_to"]).to eq(visas_apply_path(event.slug))
  end

  it "lists the events taking applications" do
    event
    create(:event, name: "Invite Only Hackathon", visa_letters: "invite_only")

    get visas_path

    expect(response.body).to include("Fictional Hackathon")
    expect(response.body).not_to include("Invite Only Hackathon")
  end

  context "signed in" do
    before { sign_in applicant }

    it "pre-fills the form from their Hack Club account" do
      get visas_apply_path(event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('value="Ada Example"', 'value="2008-04-01"', "2 Sample Road")
    end

    it "uses the birthday and mailing address on their Hack Club account, whatever the form sends" do
      post visas_apply_path(event.slug), params: { visa_letter_application: details.merge(date_of_birth: "2000-01-01", address: "Somewhere else") }

      application = VisaLetterApplication.last
      expect(application.date_of_birth).to eq(Date.new(2008, 4, 1))
      expect(application.address).to eq("2 Sample Road\nExample City\nUnited Kingdom")
    end

    it "lets them type a birthday and address their Hack Club account doesn't have" do
      applicant.update!(oidc_claims: { "legal_first_name" => "Ada", "legal_last_name" => "Example" })

      apply

      expect(VisaLetterApplication.last).to have_attributes(date_of_birth: Date.new(2008, 4, 1), address: "2 Sample Road\nExample City")
    end

    it "takes an application, confirms it and tells the reviewers" do
      expect { apply }
        .to change(VisaLetterApplication, :count).by(1)
        .and have_enqueued_mail(VisaLetterMailer, :received)
        .and have_enqueued_mail(VisaLetterMailer, :new_application)

      application = VisaLetterApplication.last
      expect(application).to have_attributes(user: applicant, email: "ada@example.com", full_name: "Ada Example", status: "pending")
      expect(response).to redirect_to(visas_application_path(application))

      get visas_apply_path(event.slug)
      expect(response).to redirect_to(visas_application_path(application))
    end

    it "shows what's wrong with an application it can't take" do
      post visas_apply_path(event.slug), params: { visa_letter_application: details.merge(full_name: "", phone: "not a phone") }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(VisaLetterApplication.count).to eq(0)
    end

    it "is closed when the event has visa letters off, or its deadline has passed" do
      event.update!(visa_letters: "off")
      get visas_apply_path(event.slug)
      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("This event is no longer accepting applications.")

      event.update!(visa_letters: "open", visa_letter_deadline: 1.week.ago.to_date.iso8601)
      apply
      expect(response).to have_http_status(:forbidden)
      expect(VisaLetterApplication.count).to eq(0)
    end

    context "when the event's letters are invite-only" do
      before { event.update!(visa_letters: "invite_only") }

      it "turns away someone who wasn't invited" do
        apply

        expect(response).to have_http_status(:forbidden)
        expect(response.body).to include("Applications for Fictional Hackathon are by invitation only.")
      end

      it "takes an invited person's application and uses up the invitation" do
        invitation = create(:visa_letter_invitation, event: event, email: "ADA@example.com")

        apply(invite: invitation.token)

        application = VisaLetterApplication.last
        expect(application.visa_letter_invitation).to eq(invitation)
        expect(invitation.reload).to be_claimed
      end

      it "explains an invitation sent to a different address" do
        invitation = create(:visa_letter_invitation, event: event, email: "someone-else@example.com")

        get visas_apply_path(event.slug, invite: invitation.token)

        expect(response).to have_http_status(:forbidden)
        expect(response.body).to include("The email address must match the invitation email (someone-else@example.com).")
      end

      it "lets someone already registered for the event apply, and links their registration" do
        registration = create(:participant_event, event: event, participant: create(:participant, email: applicant.email, user: applicant))

        apply

        expect(VisaLetterApplication.last.participant_event).to eq(registration)
      end
    end

    context "after a rejection" do
      let!(:application) { create(:visa_letter_application, event: event, user: applicant) }

      it "lets them fix a soft rejection and send the same application again" do
        application.reject!(by: create(:user), reason: "Use the name on your passport.")

        get visas_apply_path(event.slug)
        expect(response.body).to include("Use the name on your passport.")

        expect { apply }.not_to change(VisaLetterApplication, :count)
        expect(application.reload).to be_pending
        expect(application.rejection_reason).to be_nil
      end

      it "keeps a hard rejection closed, unless staff invite them again" do
        application.reject!(by: create(:user), reason: "Not eligible.", type: :hard)

        apply
        expect(response).to have_http_status(:forbidden)
        expect(application.reload).to be_hard_rejected

        invitation = create(:visa_letter_invitation, event: event, email: applicant.email)
        apply(invite: invitation.token)
        expect(application.reload).to be_pending
      end
    end

    it "shows them their own application only" do
      mine = create(:visa_letter_application, event: event, user: applicant)
      theirs = create(:visa_letter_application, event: event)

      get visas_application_path(mine)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(mine.reference_number)

      get visas_application_path(theirs)
      expect(response).to redirect_to(root_path)
    end

    it "lets them download the letter and say what the embassy decided" do
      application = create(:visa_letter_application, event: event, user: applicant)
      application.approve!(by: create(:user))
      application.issue_letter!

      get visas_application_letter_path(application)
      expect(response.media_type).to eq("application/pdf")

      post visas_application_outcome_path(application), params: { visa_outcome: "granted" }
      expect(application.reload).to be_visa_granted
    end

    it "claims a letter imported from Envoy under their email" do
      imported = create(:visa_letter_application, :imported, event: event, email: "ada@example.com")

      get visas_path

      expect(imported.reload.user).to eq(applicant)
      expect(response.body).to include(imported.reference_number)
    end
  end

  it "shows Envoy's visa FAQ to anyone" do
    get visas_faq_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Frequently Asked Questions", "What is the DS-160?")
  end

  it "lists events taking applications on the signed-out home page" do
    event

    get root_path

    expect(response.body).to include("Need a visa letter?", "Fictional Hackathon", visas_apply_path(event.slug))
  end

  it "offers registered participants a visa letter on their dashboard" do
    other_event = create(:event, name: "Somewhere Hackathon")
    create(:participant_event, event: other_event, participant: create(:participant, email: applicant.email, user: applicant))
    event
    sign_in applicant

    get dashboard_path

    expect(response.body).to include("Attending a Hack Club event, and require a visa?", "Fictional Hackathon", visas_apply_path(event.slug))
  end
end
