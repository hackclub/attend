require "rails_helper"

RSpec.describe "Asking for a visa letter", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, name: "Fictional Hackathon", visa_letters: "open", starts_at: 1.month.from_now, ends_at: 1.month.from_now + 2.days) }
  let(:applicant) do
    create(:user, email: "ada@example.com", hack_club_account_id: "ident!ada",
      oidc_claims: { "legal_first_name" => "Ada", "legal_last_name" => "Example", "birthdate" => "2008-04-01", "phone_number" => "+12025550123",
                     "addresses" => [ { "id" => "addr!home", "line_1" => "2 Sample Road", "city" => "Example City", "country" => "GB", "primary" => true } ] })
  end
  let(:details) do
    { full_name: "Ada Example", date_of_birth: "2008-04-01", nationality: "United Kingdom",
      place_of_birth: "Example City", phone: "+12025550123", address: "2 Sample Road\nExample City", address_id: "addr!home" }
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

    expect(response.body).to include("Fictional Hackathon", "Application Deadline:", event.visa_letter_closes_on.strftime("%B %d, %Y"))
    expect(response.body).not_to include("Invite Only Hackathon")
  end

  context "signed in" do
    before { sign_in applicant }

    it "pre-fills the form from their Hack Club account" do
      get visas_apply_path(event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('value="Ada Example"', 'value="2008-04-01"', "2 Sample Road",
        "It must match your passport exactly, including any middle names.")
    end

    it "leaves their citizenship for them to choose, whatever country they live in" do
      applicant.update!(oidc_claims: applicant.oidc_claims.merge("addresses" => [
        { "id" => "addr!home", "line_1" => "2 Sample Road", "city" => "Example City", "country" => "AE", "primary" => true }
      ]))
      create(:participant, user: applicant, email: applicant.email, country_of_residence: "United Arab Emirates")

      get visas_apply_path(event.slug)

      expect(response.body).to include("2 Sample Road, Example City, United Arab Emirates")
      expect(response.body).not_to include('<option selected="selected" value="United Arab Emirates">')
    end

    it "uses the birthday and mailing address on their Hack Club account, whatever the form sends" do
      post visas_apply_path(event.slug), params: { visa_letter_application: details.merge(date_of_birth: "2000-01-01", address: "Somewhere else") }

      application = VisaLetterApplication.last
      expect(application.date_of_birth).to eq(Date.new(2008, 4, 1))
      expect(application.address).to eq("2 Sample Road\nExample City\nUnited Kingdom")
    end

    it "offers every address on their Hack Club account, primary first, and uses the one they pick" do
      applicant.update!(oidc_claims: applicant.oidc_claims.merge("addresses" => [
        { "id" => "addr!school", "line_1" => "3 Example Lane", "city" => "Sample Town", "country" => "GB" },
        { "id" => "addr!home", "line_1" => "2 Sample Road", "city" => "Example City", "country" => "GB", "primary" => true }
      ]))

      get visas_apply_path(event.slug)
      expect(response.body).to include("2 Sample Road, Example City, United Kingdom", "3 Example Lane, Sample Town, United Kingdom",
        "To use a different address, add it at", "refresh from your Hack Club account")
      expect(response.body.index("2 Sample Road")).to be < response.body.index("3 Example Lane")
      expect(response.body).to include('<option selected="selected" value="addr!home">')

      post visas_apply_path(event.slug), params: { visa_letter_application: details.merge(address_id: "addr!school", address: "Somewhere else") }
      expect(VisaLetterApplication.last.address).to eq("3 Example Lane\nSample Town\nUnited Kingdom")
    end

    it "says when the address they picked isn't on their Hack Club account any more" do
      post visas_apply_path(event.slug), params: { visa_letter_application: details.merge(address_id: "addr!removed") }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Address is no longer on your Hack Club account. Please pick one below.",
        '<option selected="selected" value="addr!home">')
      expect(response.body).not_to include("Address can&#39;t be blank")
      expect(VisaLetterApplication.count).to eq(0)

      # A form from before their account had any addresses sends a typed one.
      post visas_apply_path(event.slug), params: { visa_letter_application: details.except(:address_id) }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Address needs to be one from your Hack Club account. Please pick one below.")
    end

    it "offers the one address an older sign-in kept, under a key that doesn't depend on its place in the list" do
      applicant.update!(oidc_claims: applicant.oidc_claims.except("addresses").merge(
        "address" => { "street_address" => "15 Example Rd", "locality" => "Sample Town", "region" => "VT", "country" => "US" }
      ))
      key = VisaLetterApplication.hack_club_auth_addresses(applicant).keys.sole

      get visas_apply_path(event.slug)
      expect(response.body).to include(%(<option selected="selected" value="#{key}">15 Example Rd, Sample Town, VT, United States</option>))
      expect(key).not_to eq("0")

      post visas_apply_path(event.slug), params: { visa_letter_application: details.merge(address_id: key) }
      expect(VisaLetterApplication.last.address).to eq("15 Example Rd\nSample Town, VT\nUnited States")
    end

    context "refreshing from Hack Club Auth after adding an address there" do
      around do |example|
        OmniAuth.config.test_mode = true
        example.run
      ensure
        OmniAuth.config.mock_auth[:hack_club] = nil
        OmniAuth.config.test_mode = false
      end

      it "goes through Hack Club Auth and back to the form, with the new address to pick" do
        OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(
          provider: "hack_club", uid: "ident!ada", info: { email: "ada@example.com", name: "Ada Example" },
          extra: { scope: "openid profile email address legal_name", raw_info: { "identity" => { "id" => "ident!ada", "primary_email" => "ada@example.com", "addresses" => [
            { "id" => "addr!new", "line_1" => "4 Fictional Way", "city" => "Sample Town", "country" => "GB", "primary" => true }
          ] } } }
        )

        get visas_apply_path(event.slug)
        expect(response.body).to include('form="refresh_from_hack_club_auth"', %(value="#{visas_apply_path(event.slug)}"))

        post user_hack_club_omniauth_authorize_path, params: { refresh: visas_apply_path(event.slug), extra_scopes: "visa_letter" }
        follow_redirect!
        expect(response).to redirect_to(visas_apply_path(event.slug))
        expect(flash[:notice]).to eq("Updated from your Hack Club account.")

        follow_redirect!
        expect(response.body).to include("4 Fictional Way, Sample Town, United Kingdom")
      end
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

    it "closes a week before the event starts when no deadline is set" do
      event.update!(starts_at: 3.days.from_now, ends_at: 5.days.from_now)

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

      it "lets someone already registered for the event apply, and finds their registration" do
        registration = create(:participant_event, event: event, participant: create(:participant, email: applicant.email, user: applicant))

        apply

        expect(VisaLetterApplication.last.registration).to eq(registration)
        get visas_application_path(VisaLetterApplication.last)
        expect(response.body).to include("You're registered for")
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

      it "doesn't say the name they're correcting came from their Hack Club account" do
        application.update!(full_name: "Ada Exampel")
        application.reject!(by: create(:user), reason: "The name doesn't match your passport.")

        get visas_apply_path(event.slug)

        expect(response.body).to include('value="Ada Exampel"', "It must match your passport exactly, including any middle names.")
        expect(response.body).not_to include("Filled in from your Hack Club account")
      end

      it "still shows the rejection reason when a resubmission has something to fix" do
        application.reject!(by: create(:user), reason: "Name mismatch")

        post visas_apply_path(event.slug), params: { visa_letter_application: details.merge(full_name: "Ada Quinn Example", phone: "not a phone") }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Previous Rejection Reason", "Name mismatch", 'value="Ada Quinn Example"')

        post visas_apply_path(event.slug), params: { visa_letter_application: details.merge(address_id: "addr!removed") }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Previous Rejection Reason", "Name mismatch",
          "Address is no longer on your Hack Club account. Please pick one below.")
        expect(response.body).not_to include("Address can&#39;t be blank")

        expect(application.reload).to have_attributes(status: "rejected", rejection_reason: "Name mismatch")
      end

      it "lets a soft-rejected applicant reapply from the email's link once the form is invite-only" do
        event.update!(visa_letters: "invite_only")
        application.reject!(by: create(:user), reason: "Use the name on your passport.")

        apply

        expect(application.reload).to be_pending
      end

      it "reopens a hard rejection when staff send an older, unused invitation again" do
        invitation = create(:visa_letter_invitation, event: event, email: applicant.email)
        application.reject!(by: create(:user), reason: "Not eligible.", type: :hard)
        invitation.update!(updated_at: Time.current) # what re-sending it from Manual Invitations does

        apply(invite: invitation.token)

        expect(application.reload).to be_pending
      end

      it "doesn't let the invitation they applied with undo a hard rejection" do
        invitation = create(:visa_letter_invitation, event: event, email: applicant.email)
        application.update!(visa_letter_invitation: invitation)
        invitation.claim!
        application.reject!(by: create(:user), reason: "Not eligible.", type: :hard)

        apply(invite: invitation.token)

        expect(response).to have_http_status(:forbidden)
        expect(application.reload).to be_hard_rejected
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

    it "lets them download the letter" do
      application = create(:visa_letter_application, event: event, user: applicant)
      application.approve!(by: create(:user))
      application.issue_letter!

      get visas_application_letter_path(application)
      expect(response.media_type).to eq("application/pdf")

      get visas_application_path(application)
      expect(response.body).not_to include("What did the embassy decide?")
    end

    it "claims a letter imported from Envoy under their email" do
      imported = create(:visa_letter_application, :imported, event: event, email: "ada@example.com")

      get visas_path

      expect(imported.reload.user).to eq(applicant)
      expect(response.body).to include(imported.reference_number)
    end

    it "claims an Envoy import from its emailed link or the apply form, without a second application" do
      imported = create(:visa_letter_application, :imported, event: event, email: "ada@example.com")

      get visas_application_path(imported)
      expect(response).to have_http_status(:ok)

      imported.update_columns(user_id: nil)
      get visas_apply_path(event.slug)
      expect(response).to redirect_to(visas_application_path(imported))
      expect(VisaLetterApplication.count).to eq(1)
    end

    it "holds a resubmitted Envoy import to Attend's checks" do
      imported = create(:visa_letter_application, :imported, event: event, email: "ada@example.com", user: applicant)
      imported.reject!(by: create(:user), reason: "Use the name on your passport.")

      post visas_apply_path(event.slug), params: { visa_letter_application: details.merge(phone: "not a phone") }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(imported.reload).to be_soft_rejected
    end
  end

  it "doesn't list a draft that takes applications" do
    create(:event, :draft, name: "Unannounced Hackathon", visa_letters: "open")

    get visas_path

    expect(response.body).not_to include("Unannounced Hackathon")
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
