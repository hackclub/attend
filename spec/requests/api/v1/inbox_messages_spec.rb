require "rails_helper"

RSpec.describe "Api::V1::InboxMessages", type: :request do
  let(:user) { create(:user, email: "inbox-api@example.com") }
  let(:participant) { create(:participant, user: user, email: user.email) }
  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, participant: participant, event: event, status: :complete) }
  let(:sender) { create(:user, name: "Organizer", email: "organizer-inbox@example.com") }
  let(:headers) { { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" } }
  let(:json) { JSON.parse(response.body) }

  def deliver(message, channel, status: :delivered, to: participant_event)
    message.message_deliveries.create!(participant_event: to, channel: channel, status: status, delivered_at: Time.current,
      recipient_email: "x@example.com")
  end

  let(:message) do
    event.messages.create!(sent_by_user: sender, audience: "confirmed_attendees", channels: %w[email push], subject: "Bus times",
      body: "<p>The bus leaves at <strong>9</strong></p>", status: :completed, sent_at: 1.hour.ago)
  end

  it "lists each delivered message once, however many channels it used" do
    deliver(message, "email")
    deliver(message, "push")
    other = create(:participant_event, event: event)
    deliver(message, "email", to: other)

    get api_v1_messages_path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(json["messages"].sole).to include("id" => message.id, "channels" => %w[email push], "unread" => true, "sender_name" => "Organizer")
    expect(json["unread_count"]).to eq(1)
  end

  it "leaves out deliveries that never arrived" do
    deliver(message, "email", status: :failed)

    get api_v1_messages_path, headers: headers

    expect(json["messages"]).to be_empty
  end

  it "shows a message by id and marks it read" do
    delivery = deliver(message, "email")

    get api_v1_message_path(message), headers: headers

    expect(json["message"]).to include("subject" => "Bus times", "ticket_id" => participant_event.id)
    expect(json["message"]["body_html"]).to include("<strong>9</strong>")
    expect(delivery.reload).to be_read
  end

  it "doesn't show someone else's message" do
    deliver(message, "email", to: create(:participant_event, event: event))

    get api_v1_message_path(message), headers: headers

    expect(response).to have_http_status(:not_found)
  end

  it "refuses an event API key" do
    event.generate_api_key!
    get api_v1_messages_path, headers: { "Authorization" => "Bearer #{event.api_key}" }

    expect(response).to have_http_status(:forbidden)
  end
end
