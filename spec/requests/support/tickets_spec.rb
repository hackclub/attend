require "rails_helper"

RSpec.describe "Support::Tickets", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:live_event) { create(:event, starts_at: 1.week.from_now, ends_at: 2.weeks.from_now) }
  let(:other_event) { create(:event, starts_at: 1.week.from_now, ends_at: 2.weeks.from_now) }
  let(:past_event) { create(:event, starts_at: 4.weeks.ago, ends_at: 2.weeks.ago, registration_open_at: 6.weeks.ago, registration_close_at: 5.weeks.ago) }

  let(:global_admin) { User.create!(email: "ga-tickets@example.com", name: "Global Admin", global_role: "global_admin") }
  let(:event_ops) do
    User.create!(email: "ops-tickets@example.com", name: "Event Ops").tap do |user|
      EventRoleAssignment.create!(user: user, event: live_event, role: "ops")
    end
  end
  let(:past_event_admin) do
    User.create!(email: "past-ea-tickets@example.com", name: "Past Event Admin").tap do |user|
      EventRoleAssignment.create!(user: user, event: past_event, role: "event_admin")
    end
  end
  let(:safeguarding_lead) do
    User.create!(email: "sg-tickets@example.com", name: "Safeguarding Lead").tap do |user|
      EventRoleAssignment.create!(user: user, event: live_event, role: "safeguarding_lead")
    end
  end

  def make_ticket(event: nil, phone: "+15550001111")
    Ticket.create!(channel: "whatsapp", phone_number: phone, status: "open", event: event)
  end

  let!(:pending_ticket) { make_ticket(phone: "+15550001111") }
  let!(:live_ticket) { make_ticket(event: live_event, phone: "+15550002222") }
  let!(:other_ticket) { make_ticket(event: other_event, phone: "+15550003333") }
  let!(:past_ticket) { make_ticket(event: past_event, phone: "+15550004444") }

  describe "GET index" do
    it "shows every ticket to a global admin" do
      sign_in global_admin
      get support_tickets_path

      expect(response).to have_http_status(:ok)
      [ pending_ticket, live_ticket, other_ticket, past_ticket ].each do |ticket|
        expect(response.body).to include(ticket.phone_number)
      end
    end

    it "shows event staff the pending queue and their own event's tickets only" do
      sign_in event_ops
      get support_tickets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pending_ticket.phone_number)
      expect(response.body).to include(live_ticket.phone_number)
      expect(response.body).not_to include(other_ticket.phone_number)
      expect(response.body).not_to include(past_ticket.phone_number)
    end

    it "hides the pending queue from staff whose event ended more than 7 days ago" do
      sign_in past_event_admin
      get support_tickets_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(pending_ticket.phone_number)
      expect(response.body).to include(past_ticket.phone_number)
    end

    it "denies safeguarding leads" do
      sign_in safeguarding_lead
      get support_tickets_path

      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET show" do
    it "lets active event staff open pending and own-event tickets" do
      sign_in event_ops

      get support_ticket_path(pending_ticket)
      expect(response).to have_http_status(:ok)

      get support_ticket_path(live_ticket)
      expect(response).to have_http_status(:ok)
    end

    it "denies event staff tickets linked to other events" do
      sign_in event_ops
      get support_ticket_path(other_ticket)

      expect(response).to have_http_status(:redirect)
    end

    it "denies pending tickets to staff outside their support window" do
      sign_in past_event_admin
      get support_ticket_path(pending_ticket)

      expect(response).to have_http_status(:redirect)
    end
  end

  describe "PATCH close" do
    it "lets active event staff close a pending ticket" do
      sign_in event_ops
      patch close_support_ticket_path(pending_ticket)

      expect(pending_ticket.reload).to be_closed
    end

    it "denies staff outside their support window" do
      sign_in past_event_admin
      patch close_support_ticket_path(pending_ticket)

      expect(response).to have_http_status(:redirect)
      expect(pending_ticket.reload).to be_open
    end
  end

  describe "PATCH set_event" do
    it "lets event staff link a pending ticket to their own event" do
      sign_in event_ops
      patch set_event_support_ticket_path(pending_ticket), params: { event_id: live_event.id }

      expect(pending_ticket.reload.event).to eq(live_event)
    end

    it "rejects linking to an event the user does not staff" do
      sign_in event_ops
      patch set_event_support_ticket_path(pending_ticket), params: { event_id: other_event.id }

      expect(response).to redirect_to(support_ticket_path(pending_ticket))
      expect(flash[:alert]).to be_present
      expect(pending_ticket.reload.event).to be_nil
    end

    it "lets a global admin link to any event" do
      sign_in global_admin
      patch set_event_support_ticket_path(pending_ticket), params: { event_id: other_event.id }

      expect(pending_ticket.reload.event).to eq(other_event)
    end
  end

  describe "PATCH set_subject" do
    it "rejects an event the user does not staff" do
      participant = Participant.create!(legal_first_name: "Test", legal_last_name: "Person", email: "tp@example.com", phone: pending_ticket.phone_number)

      sign_in event_ops
      patch set_subject_support_ticket_path(pending_ticket), params: { subject_type: "Participant", subject_id: participant.id, event_id: other_event.id }

      expect(flash[:alert]).to be_present
      expect(pending_ticket.reload.subject_id).to be_nil
    end
  end

  describe "POST notes" do
    it "lets active event staff add a note to a pending ticket" do
      sign_in event_ops

      expect {
        post support_ticket_notes_path(pending_ticket), params: { note: { body: "Spoke to caller", note_type: "ops" } }
      }.to change { pending_ticket.notes.count }.by(1)
    end

    it "denies note removal of someone else's note to non-authors" do
      note = pending_ticket.notes.create!(author_user_id: global_admin.id, body: "Admin note", note_type: "ops")

      sign_in event_ops
      delete support_ticket_note_path(pending_ticket, note)

      expect(flash[:alert]).to be_present
      expect(Note.exists?(note.id)).to be(true)
    end
  end
end
