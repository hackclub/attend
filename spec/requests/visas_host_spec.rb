require "rails_helper"

RSpec.describe "The visas.hackclub.com host", type: :request do
  let(:event) do
    create(:event, name: "Fictional Hackathon", slug: "fictional-hackathon", venue_name: "Example Hall",
      location_city: "Boston", location_country: "United States", timezone: "Eastern Time (US & Canada)",
      starts_at: Time.utc(2027, 3, 5, 15), ends_at: Time.utc(2027, 3, 7, 22), legacy_envoy_slug: "fictional-hack-2027")
  end
  let(:reviewer) { create(:user) }
  let(:application) { create(:visa_letter_application, event: event, full_name: "Ada Example") }

  def send_letter
    application.approve!(by: reviewer)
    application.issue_letter!(issued_on: Date.new(2027, 1, 15))
  end

  def attend(path) = AttendUrls.attend_url(path)

  before do
    create(:visa_letter_template, :default)
    host! VisaLetter.visas_host
  end

  describe "verifying a letter" do
    it "fills in the code from the link printed on the letter" do
      get "/verify", params: { code: "ABC123" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Verify Visa Letter")
      expect(response.body).to include('value="ABC123"')
    end

    it "confirms a sent letter with what the letter printed, whatever the event says now" do
      send_letter
      event.update!(name: "Renamed Hackathon", location_city: "Elsewhere")

      post "/verify", params: { code: " #{application.verification_code.downcase} " }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Letter Verified")
      expect(response.body).to include(application.reference_number)
      expect(response.body).to include("Ada Example")
      expect(response.body).to include("Fictional Hackathon")
      expect(response.body).to include("January 15, 2027")
      expect(response.body).to include("March 5–7, 2027")
      expect(response.body).to include("Boston, United States")
      expect(response.body).not_to include("Renamed Hackathon")
    end

    it "shows the same pending page for every application without a sent letter" do
      approved = create(:visa_letter_application, event: event).tap { |app| app.approve!(by: reviewer) }
      rejected = create(:visa_letter_application, event: event).tap { |app| app.reject!(by: reviewer, reason: "Wrong name", type: :hard) }

      [ application, approved, rejected ].each do |app|
        post "/verify", params: { code: app.verification_code }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Letter Pending")
        expect(response.body).not_to include("Wrong name")
        expect(response.body).not_to include(app.full_name)
      end
    end

    it "says so when the code doesn't match a letter" do
      post "/verify", params: { code: "0" * 32 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Invalid verification code. Please check and try again.")
    end

    it "stops answering after too many attempts" do
      allow(VisasHostController.cache_store).to receive(:increment).and_return(31)

      post "/verify", params: { code: "0" * 32 }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include("Too many attempts")
    end
  end

  describe "Envoy's emailed download links" do
    before { send_letter }

    it "downloads the letter with its verification code as the token" do
      get "/visa_letter_applications/#{application.id}/download_letter", params: { token: application.verification_code }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.body).to start_with("%PDF")
    end

    it "refuses a wrong or missing token, an unknown application and a letter that isn't sent" do
      pending_application = create(:visa_letter_application, event: event)

      [
        [ application.id, application.verification_code.downcase ],
        [ application.id, nil ],
        [ "not-a-uuid", application.verification_code ],
        [ SecureRandom.uuid, application.verification_code ],
        [ pending_application.id, pending_application.verification_code ]
      ].each do |id, token|
        get "/visa_letter_applications/#{id}/download_letter", params: { token: token }.compact

        expect(response).to have_http_status(:not_found)
        expect(response.body).to include("Invalid or expired download link.")
      end
    end
  end

  describe "Envoy's other pages" do
    it "sends an application's page to Attend's" do
      get "/visa_letter_applications/#{application.id}"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to eq(attend(visas_application_path(application)))
    end

    it "sends an event's page and form to its form in Attend, carrying an invitation across, temporarily" do
      event
      get "/events/fictional-hack-2027"
      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to eq(attend(visas_apply_path("fictional-hackathon")))

      get "/events/fictional-hack-2027/apply", params: { invitation: "tok3n" }
      expect(response.headers["Location"]).to eq(attend(visas_apply_path("fictional-hackathon", invite: "tok3n")))
    end

    it "sends an event Attend doesn't know to the list of events" do
      get "/events/never-imported/apply"

      expect(response.headers["Location"]).to eq(attend(visas_path))
    end

    it "sends the lookup, the FAQ, the admin and everything else to their places in Attend" do
      { "/lookup" => visas_path, "/documentation" => visas_faq_path, "/admin" => admin_root_path,
        "/admin/letter_templates" => admin_root_path, "/" => visas_path, "/events" => visas_path,
        "/visa_letter_applications/#{application.id}/verify_email" => visas_path }.each do |path, target|
        get path

        expect(response).to have_http_status(:moved_permanently), path
        expect(response.headers["Location"]).to eq(attend(target)), path
      end
    end

    it "sends an application's admin page to Attend's" do
      get "/admin/visa_letter_applications/#{application.id}"

      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to eq(attend(admin_event_visa_letter_path(event, application)))
    end

    it "refuses writes once forgery protection is on, as it is in production" do
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true

      post "/lookup", params: { reference_number: application.reference_number }

      expect(response).to have_http_status(:unprocessable_content)
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    it "still answers the health check" do
      get "/up"

      expect(response).to have_http_status(:ok)
    end
  end

  describe "on Attend's own host" do
    before { host! "www.example.com" }

    it "doesn't serve the verification page or the token downloads" do
      send_letter

      get "/verify"
      expect(response).to have_http_status(:not_found)

      get "/visa_letter_applications/#{application.id}/download_letter", params: { token: application.verification_code }
      expect(response).to have_http_status(:not_found)
    end
  end
end
