require "rails_helper"

# The visa letter form's "refresh from your Hack Club account" button: through
# Hack Club Auth and back to the form, to pick up what's just changed there.
RSpec.describe "Refreshing the visa letter form from Hack Club Auth", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:event) { create(:event, name: "Fictional Hackathon", visa_letters: "open", starts_at: 1.month.from_now, ends_at: 1.month.from_now + 2.days) }
  let(:form_path) { visas_apply_path(event.slug) }
  let(:applicant) do
    create(:user, email: "ada@example.com", hack_club_account_id: "ident!ada",
      oidc_claims: { "legal_first_name" => "Ada", "legal_last_name" => "Example", "birthdate" => "2008-04-01" })
  end
  let(:new_address) { { "id" => "addr!new", "line_1" => "4 Fictional Way", "city" => "Sample Town", "country" => "GB", "primary" => true } }
  let(:usual_scope) { "openid profile email slack_id phone birthdate verification_status" }
  let(:signed_in) { "Successfully authenticated from Hack Club Auth account." }

  def press_refresh(return_to = form_path)
    post user_hack_club_omniauth_authorize_path, params: { refresh: return_to, extra_scopes: "visa_letter" }
  end

  it "has the visa letter pages' sign-in buttons ask for what the letter needs too" do
    [ visas_path, form_path ].each do |page|
      get page

      button_form = Nokogiri::HTML(response.body).at_css("form[action='#{user_hack_club_omniauth_authorize_path}']")
      expect(button_form.at_css("input[name=extra_scopes]")&.[]("value")).to eq("visa_letter"), page
    end
  end

  context "in OmniAuth's test mode" do
    around do |example|
      OmniAuth.config.test_mode = true
      example.run
    ensure
      OmniAuth.config.mock_auth[:hack_club] = nil
      OmniAuth.config.test_mode = false
    end

    def hack_club_auth_signed_in_as(uid, email, identity = {})
      OmniAuth.config.mock_auth[:hack_club] = OmniAuth::AuthHash.new(
        provider: "hack_club", uid: uid, info: { email: email, name: "Example Person" },
        extra: { raw_info: { "identity" => { "id" => uid, "primary_email" => email }.merge(identity) },
                 scope: "#{usual_scope} address legal_name" }
      )
    end

    def refresh(return_to = form_path)
      press_refresh(return_to)
      follow_redirect!
    end

    context "signed in" do
      before { sign_in applicant }

      it "comes back to the form with what's new in Hack Club Auth" do
        hack_club_auth_signed_in_as("ident!ada", "ada@example.com", "addresses" => [ new_address ])

        refresh
        expect(response).to redirect_to(form_path)
        expect(flash[:notice]).to eq("Updated from your Hack Club account.")

        follow_redirect!
        expect(response.body).to include("4 Fictional Way, Sample Town, United Kingdom")
      end

      it "sets the form up to keep what's been typed through the round trip, but not what Hack Club Auth fills in" do
        get visas_apply_path(event.slug, invite: "example-invite")

        page = Nokogiri::HTML(response.body)
        form = page.at_css("form[data-controller~='refresh-draft']")
        expect(form["data-action"]).to eq("submit@document->refresh-draft#stash")
        expect(form["data-refresh-draft-key-value"]).to eq("visa_letter #{event.slug} #{applicant.id}")
        expect(form["data-refresh-draft-form-value"]).to eq("refresh_from_hack_club_auth")
        expect(JSON.parse(form["data-refresh-draft-from-hack-club-value"])).to eq([ "visa_letter_application[address_id]" ])
        expect(form["data-refresh-draft-submitted-value"]).to eq("false")
        # The draft leaves disabled fields alone, such as the locked birthday.
        expect(form.at_css("input[name='visa_letter_application[date_of_birth]']")["disabled"]).to be_present

        refresh_form = page.at_css("form#refresh_from_hack_club_auth")
        expect(refresh_form["action"]).to eq(user_hack_club_omniauth_authorize_path)
        expect(refresh_form.at_css("input[name=refresh]")["value"]).to eq(visas_apply_path(event.slug, invite: "example-invite"))
        expect(refresh_form.at_css("input[name=extra_scopes]")["value"]).to eq("visa_letter")
        expect(refresh_form.at_css("input[name=origin]")).to be_nil
      end

      it "keeps everything showing after a submission comes back with errors, since it's what they sent" do
        post form_path, params: { visa_letter_application: { full_name: "Ada Middle Example", place_of_birth: "" } }

        expect(response).to have_http_status(:unprocessable_content)
        form = Nokogiri::HTML(response.body).at_css("form[data-controller~='refresh-draft']")
        expect(form["data-refresh-draft-submitted-value"]).to eq("true")
      end

      it "signs in the ordinary way when Hack Club Auth is signed in as somebody else" do
        create(:user, email: "grace@example.com", hack_club_account_id: "ident!grace")
        hack_club_auth_signed_in_as("ident!grace", "grace@example.com")

        refresh
        expect(response).to redirect_to(root_path)
        expect(flash[:notice]).to eq(signed_in)

        get form_path
        expect(response.body).to include('value="grace@example.com"')
      end

      it "goes back to the form, still signed in, when the refresh fails" do
        OmniAuth.config.mock_auth[:hack_club] = :access_denied

        refresh
        expect(response).to redirect_to(form_path)
        expect(flash[:alert]).to eq("Couldn't refresh from your Hack Club account, so nothing has changed. Please try again.")

        follow_redirect!
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Apply for Visa Letter")
      end

      it "doesn't let a refresh someone gave up on steer a later sign-in" do
        hack_club_auth_signed_in_as("ident!ada", "ada@example.com")
        press_refresh

        # Gave up at Hack Club Auth, and later signed in from somewhere else.
        post user_hack_club_omniauth_authorize_path
        follow_redirect!
        expect(response).to redirect_to(root_path)
        expect(flash[:notice]).to eq(signed_in)
      end

      it "only counts the refresh's own round trip, within #{Users::OmniauthCallbacksController::REFRESH_WINDOW.inspect}" do
        hack_club_auth_signed_in_as("ident!ada", "ada@example.com")

        press_refresh
        travel(Users::OmniauthCallbacksController::REFRESH_WINDOW + 1.minute) { follow_redirect! }
        expect(response).to redirect_to(root_path)
        expect(flash[:notice]).to eq(signed_in)

        # Read once: going back to the callback again is an ordinary sign-in.
        press_refresh
        follow_redirect!
        get "/users/auth/hack_club/callback"
        expect(response).to redirect_to(root_path)

        OmniAuth.config.mock_auth[:hack_club] = :access_denied
        press_refresh
        travel(Users::OmniauthCallbacksController::REFRESH_WINDOW + 1.minute) { follow_redirect! }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq("Authentication failed. Please try again.")
      end

      it "doesn't count a refresh someone else started in this browser" do
        grace = create(:user, email: "grace@example.com", hack_club_account_id: "ident!grace")
        hack_club_auth_signed_in_as("ident!grace", "grace@example.com")

        press_refresh
        sign_in grace
        follow_redirect!
        expect(response).to redirect_to(root_path)
        expect(flash[:notice]).to eq(signed_in)
      end

      it "goes back only to a path on Attend, and signs in the ordinary way otherwise" do
        hack_club_auth_signed_in_as("ident!ada", "ada@example.com")

        [ "https://elsewhere.example/visas", "//elsewhere.example/visas", "/\\elsewhere.example", "visas",
          "/visas/a path with spaces", "/visas/<script>", "/visas/\u0001" ].each do |return_to|
          refresh(return_to)
          expect(response).to redirect_to(root_path), return_to
          expect(flash[:notice]).to eq(signed_in), return_to
        end

        OmniAuth.config.mock_auth[:hack_club] = :access_denied
        refresh("//elsewhere.example/visas")
        expect(response).to redirect_to(root_path)
      end
    end

    context "once the session here has ended" do
      it "is an ordinary sign-in, which goes on to a pending invitation" do
        invitation = create(:invitation, event: event, email: "ada@example.com", sent_at: Time.current)
        applicant
        get onboarding_path(invite: invitation.token)
        hack_club_auth_signed_in_as("ident!ada", "ada@example.com")

        refresh
        expect(response).to redirect_to(onboarding_path(invite: invitation.token))
        expect(flash[:notice]).to eq(signed_in)
      end

      it "is an ordinary sign-in, which goes back to where signing in was asked for" do
        other_event = create(:event, visa_letters: "open", starts_at: 1.month.from_now, ends_at: 1.month.from_now + 2.days)
        applicant
        get visas_apply_path(other_event.slug)
        hack_club_auth_signed_in_as("ident!ada", "ada@example.com")

        refresh
        expect(response).to redirect_to(visas_apply_path(other_event.slug))
        expect(flash[:notice]).to eq(signed_in)
      end
    end
  end

  # Without OmniAuth's test mode: what Hack Club Auth is asked for, and what
  # granting it means for what Attend keeps.
  context "through Hack Club Auth itself" do
    def through_hack_club_auth(granted:, identity:)
      authorize = URI.parse(response.location)
      asked = Rack::Utils.parse_query(authorize.query)
      json = { "Content-Type" => "application/json" }
      stub_request(:post, "https://auth.hackclub.com/oauth/token").to_return(headers: json, body: {
        access_token: "example-access-token", token_type: "Bearer", expires_in: 15_552_000, scope: granted, created_at: Time.current.to_i
      }.to_json)
      stub_request(:get, "https://auth.hackclub.com/api/v1/me").to_return(headers: json, body: { identity: identity, scopes: granted.split }.to_json)
      stub_request(:get, "https://auth.hackclub.com/oauth/userinfo").to_return(headers: json, body: { sub: identity["id"] }.to_json)

      get "/users/auth/hack_club/callback", params: { code: "example-code", state: asked["state"] }
      asked["scope"].split
    end

    it "asks for addresses and legal names from the visa letter pages alone, and keeps them through other sign-ins" do
      sign_in applicant
      identity = { "id" => "ident!ada", "primary_email" => "ada@example.com" }

      press_refresh
      asked = through_hack_club_auth(granted: "#{usual_scope} address legal_name",
        identity: identity.merge("legal_first_name" => "Ada", "legal_last_name" => "Example", "addresses" => [ new_address ]))
      expect(asked).to include("address", "legal_name")
      expect(response).to redirect_to(form_path)
      expect(flash[:notice]).to eq("Updated from your Hack Club account.")
      expect(applicant.reload.oidc_claims["addresses"]).to eq([ new_address ])

      post user_hack_club_omniauth_authorize_path
      asked = through_hack_club_auth(granted: usual_scope, identity: identity)
      expect(asked).to eq(usual_scope.split)
      expect(response).to redirect_to(root_path)
      expect(applicant.reload.oidc_claims).to include("legal_first_name" => "Ada", "legal_last_name" => "Example", "addresses" => [ new_address ])
    end
  end
end
