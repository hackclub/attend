require "rails_helper"

RSpec.describe "Guardian portal center", type: :request do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }
  let(:guardian) { create(:guardian, email: "parent@example.com", phone: "+12025550123") }
  let!(:gpe) { create(:guardian_participant_event, guardian: guardian, participant_event: participant_event) }

  before do
    allow(SecureRandom).to receive(:random_number).and_call_original
    allow(SecureRandom).to receive(:random_number).with(1_000_000).and_return(123_456)
    # Whether Turnstile is configured depends on whether credentials are
    # readable in this environment — pin it so the specs don't.
    allow(TurnstileVerifier).to receive(:verify).and_return(true)
    allow(TurnstileVerifier).to receive(:site_key).and_return(nil)
  end

  def request_code(contact)
    post guardian_portal_center_request_code_path, params: { contact: contact }
  end

  def verify_as(contact, code: "123456")
    request_code(contact)
    post guardian_portal_center_verify_path, params: { code: code }
  end

  describe "landing page" do
    it "renders the contact form" do
      get guardian_portal_center_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Find your portals")
    end
  end

  describe "requesting a code" do
    it "emails a code when the address matches a guardian" do
      expect {
        request_code("parent@example.com")
      }.to have_enqueued_mail(GuardianMailer, :portal_center_verification)

      expect(response).to redirect_to(guardian_portal_center_verify_path)
    end

    it "matches guardian emails case-insensitively" do
      expect {
        request_code("PARENT@example.com")
      }.to have_enqueued_mail(GuardianMailer, :portal_center_verification)
    end

    it "sends no email for an unknown address but responds identically" do
      expect {
        request_code("stranger@example.com")
      }.not_to have_enqueued_mail(GuardianMailer, :portal_center_verification)

      expect(response).to redirect_to(guardian_portal_center_verify_path)
    end

    it "rejects the request when the human check fails" do
      allow(TurnstileVerifier).to receive(:verify).and_return(false)

      expect {
        request_code("parent@example.com")
      }.not_to have_enqueued_mail(GuardianMailer, :portal_center_verification)

      expect(response).to redirect_to(guardian_portal_center_path)
      expect(flash[:alert]).to include("human")
    end

    it "rejects an invalid contact" do
      request_code("not-a-contact")

      expect(response).to redirect_to(guardian_portal_center_path)
      expect(flash[:alert]).to include("valid email address or phone number")
    end

    it "rejects phone numbers when Twilio Verify is unavailable" do
      request_code("+12025550123")

      expect(response).to redirect_to(guardian_portal_center_path)
      expect(flash[:alert]).to include("Phone verification isn't available")
    end

    context "when Twilio Verify is available" do
      before { allow(TwilioVerifyService).to receive(:available?).and_return(true) }

      it "starts an SMS verification when the phone number matches a guardian" do
        expect {
          request_code("+12025550123")
        }.to have_enqueued_job(StartGuardianPortalVerificationJob).with("+12025550123", "sms")

        expect(response).to redirect_to(guardian_portal_center_verify_path)
      end

      it "starts nothing for an unknown phone number but responds identically" do
        expect {
          request_code("+12025559999")
        }.not_to have_enqueued_job(StartGuardianPortalVerificationJob)

        expect(response).to redirect_to(guardian_portal_center_verify_path)
      end

      context "with WhatsApp switched on" do
        before do
          allow(Setting).to receive(:twilio_verify_whatsapp?).and_return(true)
          guardian.update!(phone: "+447911123456")
        end

        it "sends the code on WhatsApp to a number outside +1 and offers a text instead" do
          expect {
            request_code("+447911123456")
          }.to have_enqueued_job(StartGuardianPortalVerificationJob).with("+447911123456", "whatsapp")

          follow_redirect!
          expect(response.body).to include("Check your WhatsApp")
          expect(response.body).to include("Text me the code instead")
        end

        it "shows the same WhatsApp page for a number we don't hold" do
          request_code("+447911123999")
          follow_redirect!

          expect(response.body).to include("Check your WhatsApp")
        end

        it "texts the code when the guardian asks for SMS" do
          request_code("+447911123456")

          expect {
            post guardian_portal_center_request_code_path, params: { contact: "+447911123456", channel: "sms" }
          }.to have_enqueued_job(StartGuardianPortalVerificationJob).with("+447911123456", "sms")

          follow_redirect!
          expect(response.body).to include("Check your messages")
        end

        it "keeps +1 numbers on SMS" do
          guardian.update!(phone: "+12025550123")

          expect {
            request_code("+12025550123")
          }.to have_enqueued_job(StartGuardianPortalVerificationJob).with("+12025550123", "sms")
        end
      end
    end
  end

  describe "verifying a code" do
    it "rejects a wrong code" do
      request_code("parent@example.com")
      post guardian_portal_center_verify_path, params: { code: "000000" }

      expect(response).to redirect_to(guardian_portal_center_verify_path)
      expect(flash[:alert]).to include("doesn't match")
    end

    it "locks out after too many wrong attempts" do
      request_code("parent@example.com")
      6.times { post guardian_portal_center_verify_path, params: { code: "000000" } }

      expect(response).to redirect_to(guardian_portal_center_path)
      expect(flash[:alert]).to include("Too many incorrect attempts")

      # A correct code no longer works — the pending verification is gone.
      post guardian_portal_center_verify_path, params: { code: "123456" }
      expect(response).to redirect_to(guardian_portal_center_path)
    end

    it "rejects an expired code" do
      request_code("parent@example.com")

      travel 11.minutes do
        post guardian_portal_center_verify_path, params: { code: "123456" }
      end

      expect(response).to redirect_to(guardian_portal_center_path)
      expect(flash[:alert]).to include("expired")
    end

    it "accepts the correct code and shows the portals" do
      verify_as("parent@example.com")

      expect(response).to redirect_to(guardian_portal_center_portals_path)
      follow_redirect!
      expect(response.body).to include(event.name)
      expect(response.body).to include(participant_event.participant.full_name)
    end
  end

  describe "verifying a phone code" do
    before { allow(TwilioVerifyService).to receive(:available?).and_return(true) }

    it "rejects a code Twilio Verify doesn't approve" do
      allow_any_instance_of(TwilioVerifyService).to receive(:check).and_return(false)

      verify_as("+12025550123", code: "000000")

      expect(response).to redirect_to(guardian_portal_center_verify_path)
      expect(flash[:alert]).to include("doesn't match")
    end

    it "never asks Twilio about a number no code was sent to" do
      expect_any_instance_of(TwilioVerifyService).not_to receive(:check)

      verify_as("+12025559999")

      expect(flash[:alert]).to include("doesn't match")
    end

    it "asks the guardian to retry when Twilio Verify errors" do
      allow_any_instance_of(TwilioVerifyService).to receive(:check)
        .and_raise(TwilioVerifyService::Error, "Twilio Verify error 20003: Authenticate")

      verify_as("+12025550123")

      expect(response).to redirect_to(guardian_portal_center_verify_path)
      expect(flash[:alert]).to include("couldn't check that code")
    end
  end

  describe "portals overview" do
    it "requires verification" do
      get guardian_portal_center_portals_path

      expect(response).to redirect_to(guardian_portal_center_path)
    end

    it "expires the verified session after an hour" do
      verify_as("parent@example.com")

      travel 61.minutes do
        get guardian_portal_center_portals_path
        expect(response).to redirect_to(guardian_portal_center_path)
      end
    end

    it "lists pending and completed portals across guardians with the same contact" do
      other_pe = create(:participant_event, event: create(:event))
      other_guardian = create(:guardian, email: "PARENT@example.com")
      completed_gpe = create(:guardian_participant_event, guardian: other_guardian, participant_event: other_pe,
                             status: :completed, completed_at: 2.days.ago)

      verify_as("parent@example.com")
      follow_redirect!

      expect(response.body).to include("Needs you")
      expect(response.body).to include(gpe.participant_event.event.name)
      expect(response.body).to include("Completed")
      expect(response.body).to include(completed_gpe.participant_event.event.name)
    end

    it "hides pending portals for withdrawn participants" do
      participant_event.update!(status: :withdrawn)

      verify_as("parent@example.com")
      follow_redirect!

      expect(response.body).to include("Nothing linked to this contact")
    end

    it "matches guardians by verified phone number" do
      allow(TwilioVerifyService).to receive(:available?).and_return(true)
      allow_any_instance_of(TwilioVerifyService).to receive(:check)
        .with(to: "+12025550123", code: "123456").and_return(true)

      verify_as("+12025550123")
      follow_redirect!

      expect(response.body).to include(event.name)
    end
  end

  describe "opening a portal" do
    it "redirects into the guardian portal with a valid token" do
      verify_as("parent@example.com")
      post guardian_portal_center_open_path(id: gpe.id)

      token = gpe.reload.invite_token
      expect(token).to be_present
      expect(response).to redirect_to(guardian_portal_path(token: token))

      follow_redirect!
      expect(response).to have_http_status(:ok)
    end

    it "refreshes an expired invite so the link works again" do
      gpe.generate_invite_token!
      gpe.update!(invite_token_sent_at: 8.days.ago)
      expect(gpe.invite_expired?).to be(true)

      verify_as("parent@example.com")
      post guardian_portal_center_open_path(id: gpe.id)

      expect(gpe.reload.invite_expired?).to be(false)
      expect(response).to redirect_to(guardian_portal_path(token: gpe.invite_token))
    end

    it "refuses portals belonging to other guardians" do
      other_gpe = create(:guardian_participant_event, guardian: create(:guardian), participant_event: create(:participant_event, event: event))

      verify_as("parent@example.com")
      post guardian_portal_center_open_path(id: other_gpe.id)

      expect(other_gpe.reload.invite_token_digest).to be_nil
      expect(response).to have_http_status(:redirect)
      expect(response.location).not_to include("/guardian/portal/")
    end

    it "requires verification" do
      post guardian_portal_center_open_path(id: gpe.id)

      expect(response).to redirect_to(guardian_portal_center_path)
    end
  end

  describe "signing out" do
    it "clears the verified session" do
      verify_as("parent@example.com")
      delete guardian_portal_center_session_path

      expect(response).to redirect_to(guardian_portal_center_path)
      get guardian_portal_center_portals_path
      expect(response).to redirect_to(guardian_portal_center_path)
    end
  end

  describe "error pages" do
    it "links the portal center from the invalid-link page" do
      get guardian_portal_path(token: "bogus-token")

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include(guardian_portal_center_path)
    end

    it "links the portal center when an expired token is used" do
      # Expired tokens raise in find_by_invite_token!, so guardians land on the
      # generic error page rather than the dedicated expired page.
      token = gpe.generate_invite_token!
      gpe.update!(invite_token_sent_at: 8.days.ago)

      get guardian_portal_path(token: token)

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include(guardian_portal_center_path)
    end
  end
end
