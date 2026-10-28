require "rails_helper"

RSpec.describe "Admin::Messages", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { User.create!(email: "admin-test@example.com", name: "Admin", global_role: "global_admin", admin_console_beta: false) }
  let(:event) { create(:event) }

  before { sign_in admin }

  describe "GET new" do
    it "renders the compose form without creating a draft" do
      expect {
        get new_admin_event_message_path(event_slug: event.slug)
      }.not_to change(Message, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Compose Message")
    end

    context "with the admin console beta" do
      before { admin.update!(admin_console_beta: true) }

      it "renders the sentence-case compose form without creating a draft" do
        expect {
          get new_admin_event_message_path(event_slug: event.slug)
        }.not_to change(Message, :count)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Compose message")
      end
    end
  end

  describe "POST create" do
    let(:params) do
      { message: { audience: "confirmed_attendees", channels: [ "slack" ], subject: "Hi", body: "<p>Hello</p>" } }
    end

    it "creates a draft owned by the current user and redirects to preview" do
      expect {
        post admin_event_messages_path(event_slug: event.slug), params: params
      }.to change(Message, :count).by(1)

      message = Message.last
      expect(message.status).to eq("draft")
      expect(message.sent_by_user).to eq(admin)
      expect(message.body).to eq("<p>Hello</p>")
      expect(response).to redirect_to(preview_admin_event_message_path(event_slug: event.slug, id: message))
    end

    it "responds with JSON for autosave including the update url" do
      post admin_event_messages_path(event_slug: event.slug, format: :json), params: params

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["update_url"]).to be_present
      expect(body["edit_url"]).to be_present
    end
  end

  describe "POST send_now" do
    let(:message) do
      event.messages.create!(audience: "confirmed_attendees", channels: [ "email" ], body: "<p>Hello</p>",
        sent_by_user: admin, status: :draft)
    end

    let(:message_send_logs) { AuditLog.where(action: "send_now", record_type: "Message") }

    before do
      create(:participant_event, event: event, status: :complete)
      # Devise's trackable updates the user on the session's first request,
      # and the audit logger would log that instead of the message. Spend it.
      get admin_event_message_path(event_slug: event.slug, id: message)
    end

    it "sends a draft and audit-logs the send" do
      expect {
        post send_now_admin_event_message_path(event_slug: event.slug, id: message)
      }.to change(MessageDelivery, :count).by(1)
        .and change(message_send_logs, :count).by(1)

      expect(message.reload).to be_sending
      expect(flash[:notice]).to eq("Message is being sent to 1 recipient.")
    end

    it "refuses a message that was sent after it was loaded, without logging a second send" do
      # Simulate a double-click: another request wins the row lock and sends
      # the message between this request's load and its send!.
      raced = false
      allow_any_instance_of(Message).to receive(:send!).and_wrap_original do |original, *args|
        unless raced
          raced = true
          Message.find(original.receiver.id).send!
        end
        original.call(*args)
      end

      expect {
        post send_now_admin_event_message_path(event_slug: event.slug, id: message)
      }.to change(MessageDelivery, :count).by(1)


      expect(response).to redirect_to(admin_event_message_path(event_slug: event.slug, id: message))
      expect(flash[:alert]).to eq("This message has already been sent.")
      expect(message.reload).to be_sending
    end
  end

  describe "POST send_to_new_recipients" do
    let(:message) do
      event.messages.create!(audience: "confirmed_attendees", channels: [ "email" ], body: "<p>Hello</p>",
        sent_by_user: admin, status: :draft)
    end

    def send_and_complete(message)
      message.send!
      message.update!(status: :completed)
    end

    it "sends a completed message to people who joined the audience since" do
      create(:participant_event, event: event, status: :complete)
      send_and_complete(message)
      travel 2.minutes
      latecomer = create(:participant_event, event: event, status: :complete)

      get admin_event_message_path(event_slug: event.slug, id: message)
      expect(response.body).to include("Send to 1 New Recipient")

      expect {
        post send_to_new_recipients_admin_event_message_path(event_slug: event.slug, id: message)
      }.to change(MessageDelivery, :count).by(1)

      expect(message.message_deliveries.last.participant_event).to eq(latecomer)
      expect(response).to redirect_to(admin_event_message_path(event_slug: event.slug, id: message))
      expect(flash[:notice]).to eq("Sending to 1 new recipient...")

      get admin_event_message_path(event_slug: event.slug, id: message)
      expect(response.body).not_to include("New Recipient")
      expect(response.body).to include("Sent later")
    end

    it "offers the button and marks late deliveries in the admin console beta" do
      admin.update!(admin_console_beta: true)
      create(:participant_event, event: event, status: :complete)
      send_and_complete(message)
      travel 2.minutes
      create(:participant_event, event: event, status: :complete)

      get admin_event_message_path(event_slug: event.slug, id: message)
      expect(response.body).to include("Send to 1 new recipient")

      post send_to_new_recipients_admin_event_message_path(event_slug: event.slug, id: message)
      get admin_event_message_path(event_slug: event.slug, id: message)
      expect(response.body).not_to include("Send to 1 new recipient")
      expect(response.body).to include("Sent later")
    end

    it "hides the button while the message is still sending and shows it once completed" do
      create(:participant_event, event: event, status: :complete)
      message.send!
      travel 2.minutes
      create(:participant_event, event: event, status: :complete)

      expect(message.reload).to be_sending
      get admin_event_message_path(event_slug: event.slug, id: message)
      expect(response.body).not_to include("New Recipient")

      message.update!(status: :completed)
      get admin_event_message_path(event_slug: event.slug, id: message)
      expect(response.body).to include("Send to 1 New Recipient")
    end

    it "offers the button on a failed message" do
      create(:participant_event, event: event, status: :complete)
      message.send!
      message.update!(status: :failed)
      travel 2.minutes
      create(:participant_event, event: event, status: :complete)

      get admin_event_message_path(event_slug: event.slug, id: message)
      expect(response.body).to include("Send to 1 New Recipient")
    end

    it "tells staff when no one new matches" do
      create(:participant_event, event: event, status: :complete)
      send_and_complete(message)

      expect {
        post send_to_new_recipients_admin_event_message_path(event_slug: event.slug, id: message)
      }.not_to change(MessageDelivery, :count)

      expect(flash[:notice]).to eq("No one new matches this audience.")
    end

    it "pluralises the notice for several new recipients" do
      create(:participant_event, event: event, status: :complete)
      send_and_complete(message)
      travel 2.minutes
      create_list(:participant_event, 2, event: event, status: :complete)

      expect {
        post send_to_new_recipients_admin_event_message_path(event_slug: event.slug, id: message)
      }.to change(MessageDelivery, :count).by(2)

      expect(flash[:notice]).to eq("Sending to 2 new recipients...")
    end

    it "refuses a message that is still sending" do
      create(:participant_event, event: event, status: :complete)
      message.send!
      create(:participant_event, event: event, status: :complete)

      expect {
        post send_to_new_recipients_admin_event_message_path(event_slug: event.slug, id: message)
      }.not_to change(MessageDelivery, :count)

      expect(flash[:alert]).to eq("This message is still sending.")
    end

    it "refuses a message that hasn't been sent" do
      create(:participant_event, event: event, status: :complete)

      expect {
        post send_to_new_recipients_admin_event_message_path(event_slug: event.slug, id: message)
      }.not_to change(MessageDelivery, :count)

      expect(flash[:alert]).to eq("This message hasn't been sent yet.")
    end

    it "refuses a cancelled scheduled message" do
      create(:participant_event, event: event, status: :complete)
      message.update!(status: :cancelled, scheduled_at: 1.day.from_now)

      expect {
        post send_to_new_recipients_admin_event_message_path(event_slug: event.slug, id: message)
      }.not_to change(MessageDelivery, :count)
    end
  end

  describe "GET show" do
    let(:message) do
      event.messages.create!(audience: "confirmed_attendees", channels: [ "email" ], body: "<p>Hello</p>",
        sent_by_user: admin, status: :draft)
    end

    # Turbo only reads data-turbo-confirm; a bare data-confirm sends on the
    # first click.
    def send_now_form
      Nokogiri::HTML(response.body).at_css("form[action='#{send_now_admin_event_message_path(event_slug: event.slug, id: message)}']")
    end

    it "asks before sending a draft" do
      get admin_event_message_path(event_slug: event.slug, id: message)

      expect(send_now_form["data-turbo-confirm"]).to eq("Are you sure you want to send this message now?")
    end

    context "with the admin console beta" do
      before { admin.update!(admin_console_beta: true) }

      it "asks before sending a draft" do
        get admin_event_message_path(event_slug: event.slug, id: message)

        expect(send_now_form["data-turbo-confirm"]).to eq("Are you sure you want to send this message now?")
      end
    end
  end
end
