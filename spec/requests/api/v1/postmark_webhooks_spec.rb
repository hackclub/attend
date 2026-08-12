require "rails_helper"

RSpec.describe "Api::V1::PostmarkWebhooks", type: :request do
  let(:webhook_username) { "postmark_user" }
  let(:webhook_password) { "postmark_secret" }
  let(:valid_credentials) { ActionController::HttpAuthentication::Basic.encode_credentials(webhook_username, webhook_password) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("POSTMARK_WEBHOOK_USERNAME").and_return(webhook_username)
    allow(ENV).to receive(:[]).with("POSTMARK_WEBHOOK_PASSWORD").and_return(webhook_password)
  end

  describe "authentication" do
    context "with valid credentials" do
      it "returns 200 OK" do
        post api_v1_postmark_webhooks_path,
          params: { RecordType: "Delivery", MessageID: "test-123" }.to_json,
          headers: { "Authorization" => valid_credentials, "Content-Type" => "application/json" }

        expect(response).to have_http_status(:ok)
      end
    end

    context "with invalid credentials" do
      it "returns 401 Unauthorized" do
        invalid_credentials = ActionController::HttpAuthentication::Basic.encode_credentials("wrong", "creds")

        post api_v1_postmark_webhooks_path,
          params: { RecordType: "Delivery", MessageID: "test-123" }.to_json,
          headers: { "Authorization" => invalid_credentials, "Content-Type" => "application/json" }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with missing credentials" do
      it "returns 401 Unauthorized" do
        post api_v1_postmark_webhooks_path,
          params: { RecordType: "Delivery", MessageID: "test-123" }.to_json,
          headers: { "Content-Type" => "application/json" }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when credentials are not configured (fail closed)" do
      before do
        allow(ENV).to receive(:[]).with("POSTMARK_WEBHOOK_USERNAME").and_return(nil)
        allow(ENV).to receive(:[]).with("POSTMARK_WEBHOOK_PASSWORD").and_return(nil)
        allow(Rails.application.credentials).to receive(:dig).and_return(nil)
      end

      it "returns 401 Unauthorized even with any credentials" do
        post api_v1_postmark_webhooks_path,
          params: { RecordType: "Delivery", MessageID: "test-123" }.to_json,
          headers: { "Authorization" => valid_credentials, "Content-Type" => "application/json" }

        expect(response).to have_http_status(:unauthorized)
      end

      it "logs an error about missing configuration" do
        expect(Rails.logger).to receive(:error).with(/Basic auth credentials are not configured/)

        post api_v1_postmark_webhooks_path,
          params: { RecordType: "Delivery", MessageID: "test-123" }.to_json,
          headers: { "Authorization" => valid_credentials, "Content-Type" => "application/json" }
      end
    end
  end

  describe "POST /api/v1/postmark_webhooks" do
    let!(:email_log) { create(:email_log, postmark_message_id: "msg-12345") }
    let(:headers) { { "Authorization" => valid_credentials, "Content-Type" => "application/json" } }

    describe "Delivery events" do
      let(:payload) do
        {
          RecordType: "Delivery",
          MessageID: "msg-12345",
          DeliveredAt: "2024-12-22T10:30:00Z",
          Recipient: "user@example.com",
          ServerID: 123456
        }
      end

      it "updates email log status to delivered" do
        post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        email_log.reload
        expect(email_log.status).to eq("delivered")
        expect(email_log.delivered_at).to be_present
      end

      it "creates a delivered event" do
        expect {
          post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers
        }.to change(EmailLogEvent, :count).by(1)

        event = email_log.email_log_events.last
        expect(event.event_type).to eq("delivered")
        expect(event.metadata["recipient"]).to eq("user@example.com")
      end

      it "does not update status if email is already bounced" do
        email_log.update!(status: "bounced", bounced_at: 1.hour.ago)

        post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        email_log.reload
        expect(email_log.status).to eq("bounced")
      end

      it "still creates event even if status is bounced" do
        email_log.update!(status: "bounced", bounced_at: 1.hour.ago)

        expect {
          post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers
        }.to change(EmailLogEvent, :count).by(1)
      end

      context "when email log not found" do
        it "returns 200 OK and logs a warning" do
          payload[:MessageID] = "unknown-msg-id"
          expect(Rails.logger).to receive(:warn).with(/No email log found/)

          post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers

          expect(response).to have_http_status(:ok)
        end
      end
    end

    describe "Bounce events" do
      let(:payload) do
        {
          RecordType: "Bounce",
          MessageID: "msg-12345",
          BouncedAt: "2024-12-22T10:30:00Z",
          Type: "HardBounce",
          TypeCode: 1,
          Description: "The email account does not exist",
          Details: "smtp;550 5.1.1 User unknown"
        }
      end

      it "updates email log status to bounced with details" do
        post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        email_log.reload
        expect(email_log.status).to eq("bounced")
        expect(email_log.bounced_at).to be_present
        expect(email_log.bounce_type).to eq("HardBounce")
        expect(email_log.bounce_description).to eq("The email account does not exist")
      end

      it "creates a bounced event with metadata" do
        expect {
          post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers
        }.to change(EmailLogEvent, :count).by(1)

        event = email_log.email_log_events.last
        expect(event.event_type).to eq("bounced")
        expect(event.metadata["bounce_type"]).to eq("HardBounce")
        expect(event.metadata["description"]).to eq("The email account does not exist")
      end
    end

    describe "Open events" do
      let(:payload) do
        {
          RecordType: "Open",
          MessageID: "msg-12345",
          ReceivedAt: "2024-12-22T11:00:00Z",
          UserAgent: "Mozilla/5.0",
          Geo: { "City" => "San Francisco" },
          Platform: "Desktop",
          Client: { "Name" => "Chrome" }
        }
      end

      before { email_log.update!(status: "delivered", delivered_at: 1.hour.ago) }

      it "updates email log status to opened" do
        post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        email_log.reload
        expect(email_log.status).to eq("opened")
        expect(email_log.opened_at).to be_present
      end

      it "creates an opened event with metadata" do
        expect {
          post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers
        }.to change(EmailLogEvent, :count).by(1)

        event = email_log.email_log_events.last
        expect(event.event_type).to eq("opened")
        expect(event.metadata["user_agent"]).to eq("Mozilla/5.0")
        expect(event.metadata["platform"]).to eq("Desktop")
      end

      it "does not update status if email is already bounced" do
        email_log.update!(status: "bounced", bounced_at: 1.hour.ago)

        post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        email_log.reload
        expect(email_log.status).to eq("bounced")
      end

      it "preserves original opened_at on subsequent opens" do
        original_opened_at = 30.minutes.ago
        email_log.update!(status: "opened", opened_at: original_opened_at)

        post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers

        email_log.reload
        expect(email_log.opened_at).to be_within(1.second).of(original_opened_at)
      end
    end

    describe "Click events" do
      let(:payload) do
        {
          RecordType: "Click",
          MessageID: "msg-12345",
          ReceivedAt: "2024-12-22T11:15:00Z",
          OriginalLink: "https://hackclub.com/events",
          ClickLocation: "HTML",
          UserAgent: "Mozilla/5.0"
        }
      end

      before { email_log.update!(status: "opened", opened_at: 1.hour.ago) }

      it "creates a link_clicked event" do
        expect {
          post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers
        }.to change(EmailLogEvent, :count).by(1)

        event = email_log.email_log_events.last
        expect(event.event_type).to eq("link_clicked")
        expect(event.metadata["original_link"]).to eq("https://hackclub.com/events")
      end

      it "does not change email log status" do
        post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers

        email_log.reload
        expect(email_log.status).to eq("opened")
      end
    end

    describe "Unhandled events" do
      it "returns 200 OK for unhandled record types" do
        post api_v1_postmark_webhooks_path,
          params: { RecordType: "SpamComplaint", MessageID: "msg-12345" }.to_json,
          headers: headers

        expect(response).to have_http_status(:ok)
      end
    end

    describe "error handling" do
      it "returns 200 OK even when database update fails" do
        allow_any_instance_of(EmailLog).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(email_log))

        expect(Rails.logger).to receive(:error).with(/Failed to record delivery/)

        post api_v1_postmark_webhooks_path,
          params: { RecordType: "Delivery", MessageID: "msg-12345", DeliveredAt: "2024-12-22T10:30:00Z" }.to_json,
          headers: headers

        expect(response).to have_http_status(:ok)
      end
    end

    describe "timestamp parsing" do
      it "handles valid ISO timestamps" do
        payload = {
          RecordType: "Delivery",
          MessageID: "msg-12345",
          DeliveredAt: "2024-12-22T10:30:00Z"
        }

        post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers

        email_log.reload
        expect(email_log.delivered_at).to eq(Time.zone.parse("2024-12-22T10:30:00Z"))
      end

      it "falls back to current time for invalid timestamps" do
        payload = {
          RecordType: "Delivery",
          MessageID: "msg-12345",
          DeliveredAt: "not-a-date"
        }

        post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers

        email_log.reload
        expect(email_log.delivered_at).to be_within(5.seconds).of(Time.current)
      end

      it "falls back to current time for blank timestamps" do
        payload = {
          RecordType: "Delivery",
          MessageID: "msg-12345",
          DeliveredAt: ""
        }

        post api_v1_postmark_webhooks_path, params: payload.to_json, headers: headers

        email_log.reload
        expect(email_log.delivered_at).to be_within(5.seconds).of(Time.current)
      end
    end
  end
end
