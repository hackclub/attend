require "rails_helper"

RSpec.describe "Dashboard messages", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user, email: user.email) }
  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, participant: participant, event: event, status: :complete) }
  let(:sender) { create(:user, name: "Example Organizer") }
  let(:message) do
    event.messages.create!(sent_by_user: sender, audience: "confirmed_attendees", channels: %w[email push],
      subject: "Example subject", body: "<p>Example body</p>", status: :completed, sent_at: 1.hour.ago)
  end

  def deliver(channel)
    message.message_deliveries.create!(participant_event: participant_event, channel: channel, status: :delivered,
      delivered_at: Time.current, recipient_email: "recipient@example.com")
  end

  before { sign_in user }

  it "marks every delivery of a message read when it is first opened" do
    email = deliver("email")
    push = deliver("push")

    get dashboard_message_path(email)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Example subject")
    expect([ email, push ].map { |delivery| delivery.reload.read? }).to all(be(true))
  end

  it "doesn't write when the message is opened again" do
    delivery = deliver("email")
    get dashboard_message_path(delivery)
    read_at = delivery.reload.read_at
    GetWriteDetector.drain

    get dashboard_message_path(delivery)

    expect(response).to have_http_status(:ok)
    expect(GetWriteDetector.drain).to be_empty
    expect(delivery.reload.read_at).to eq(read_at)
  end
end
