require "rails_helper"

RSpec.describe "Api::V1::Messages", type: :request do
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:user) do
    create(:user, name: "Ops", email: "ops-api-messages@example.com").tap do |u|
      EventRoleAssignment.create!(user: u, event: event, role: "ops")
    end
  end
  let(:headers) { { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" } }
  let(:json) { JSON.parse(response.body) }

  def draft(**attrs)
    event.messages.create!({ sent_by_user: user, audience: "confirmed_attendees", channels: [ "email" ], subject: "Hi", body: "<p>Hello</p>", status: :draft }.merge(attrs))
  end

  it "refuses someone without access to the event" do
    outsider = create(:user, email: "outsider-api-messages@example.com")
    get api_v1_event_messages_path(event), headers: { "Authorization" => "Bearer #{MobileToken.generate_for(outsider).token}" }

    expect(response).to have_http_status(:forbidden)
  end

  describe "POST create" do
    it "saves a draft owned by the caller, folding picks into audience_filters" do
      pe = create(:participant_event, event: event, status: :complete)

      expect {
        post api_v1_event_messages_path(event), headers: headers, as: :json, params: {
          message: { audience: "specific_participants", channels: [ "email" ], subject: "Hi", body: "<p>Hello</p>", participant_event_ids: [ pe.id ] }
        }
      }.to change(Message, :count).by(1)

      expect(response).to have_http_status(:created)
      message = Message.last
      expect(message).to have_attributes(status: "draft", sent_by_user: user)
      expect(message.audience_filters).to eq("participant_event_ids" => [ pe.id ])
      expect(json["message"]["participant_event_ids"]).to eq([ pe.id ])
    end

    it "starts a draft with no body as an empty one" do
      post api_v1_event_messages_path(event), headers: headers, as: :json, params: { message: { audience: "confirmed_attendees", channels: [ "email" ] } }

      expect(response).to have_http_status(:created)
      expect(Message.last.body).to eq("")
    end

    it "reports validation errors" do
      post api_v1_event_messages_path(event), headers: headers, as: :json, params: { message: { audience: "confirmed_attendees", channels: [], body: "x" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["errors"]).to be_present
    end
  end

  describe "GET preview" do
    it "counts recipients and renders each channel" do
      create(:participant_event, event: event, status: :complete)
      message = draft(channels: %w[email sms slack], body: "<p>Hello <strong>there</strong></p>")

      get preview_api_v1_event_message_path(event, message), headers: headers

      expect(json["preview"]).to include("total_count" => 1, "sms_text" => "Hello there", "slack_text" => "Hello *there*")
      expect(json["preview"]["recipient_names"].size).to eq(1)
    end
  end

  describe "POST send_now" do
    it "sends a draft once" do
      create(:participant_event, event: event, status: :complete)
      message = draft

      expect {
        post send_now_api_v1_event_message_path(event, message), headers: headers
      }.to have_enqueued_job(MessageDeliveryJob)
      expect(message.reload).to be_sending

      post send_now_api_v1_event_message_path(event, message), headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("This message has already been sent.")
    end

    it "schedules a message whose time is still ahead" do
      message = draft(scheduled_at: 1.day.from_now)

      post send_now_api_v1_event_message_path(event, message), headers: headers

      expect(message.reload).to be_scheduled
      expect(json["notice"]).to start_with("Message scheduled for")
    end
  end

  describe "PATCH update" do
    it "refuses to edit a sent message" do
      message = draft(status: :completed, sent_at: 1.hour.ago)

      patch api_v1_event_message_path(event, message), headers: headers, as: :json, params: { message: { subject: "Changed" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(message.reload.subject).to eq("Hi")
    end
  end

  describe "GET show" do
    it "hides SMS numbers from PII-restricted roles" do
      user.event_role_assignments.update_all(role: "limited")
      pe = create(:participant_event, event: event, status: :complete)
      message = draft(channels: %w[sms email], status: :completed, sent_at: 1.hour.ago)
      message.message_deliveries.create!(participant_event: pe, channel: "sms", recipient_phone: "+12025551234", status: :delivered)
      message.message_deliveries.create!(participant_event: pe, channel: "email", recipient_email: "p@example.com", status: :failed)

      get api_v1_event_message_path(event, message), headers: headers

      deliveries = json["message"]["recipients"].sole["deliveries"].index_by { |d| d["channel"] }
      expect(deliveries["sms"]["recipient_identifier"]).to be_nil
      expect(deliveries["email"]["recipient_identifier"]).to eq("p@example.com")
    end
  end

  describe "POST retry_delivery" do
    it "requeues one failed delivery" do
      pe = create(:participant_event, event: event, status: :complete)
      message = draft(status: :failed, sent_at: 1.hour.ago)
      delivery = message.message_deliveries.create!(participant_event: pe, channel: "email", recipient_email: "p@example.com", status: :failed, error_message: "Bounced")

      expect {
        post retry_delivery_api_v1_event_message_path(event, message), params: { delivery_id: delivery.id }, headers: headers
      }.to have_enqueued_job(SingleDeliveryJob)

      expect(delivery.reload).to have_attributes(status: "pending", error_message: nil)
    end
  end

  describe "DELETE destroy" do
    it "deletes a draft but not a sent message" do
      sent = draft(status: :completed, sent_at: 1.hour.ago)
      delete api_v1_event_message_path(event, sent), headers: headers
      expect(response).to have_http_status(:unprocessable_entity)

      message = draft
      expect { delete api_v1_event_message_path(event, message), headers: headers }.to change(Message, :count).by(-1)
    end
  end
end
