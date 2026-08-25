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

  describe "GET show WhatsApp reply window" do
    it "warns and disables the composer when the 24-hour window has closed" do
      live_ticket.update!(last_inbound_at: 30.hours.ago)
      sign_in global_admin
      get support_ticket_path(live_ticket)

      expect(response.body).to include("WhatsApp reply window closed")
      expect(response.body).to include("disabled=\"disabled\"")
    end

    it "shows the remaining time and leaves the composer usable inside the window" do
      live_ticket.update!(last_inbound_at: 2.hours.ago)
      sign_in global_admin
      get support_ticket_path(live_ticket)

      expect(response.body).to include("Freeform replies accepted for another")
      expect(response.body).not_to include("disabled=\"disabled\"")
    end

    it "does not mention the window on SMS tickets" do
      sms_ticket = Ticket.create!(channel: "sms", phone_number: "+15550009999", status: "open", event: live_event, last_inbound_at: 5.days.ago)
      sign_in global_admin
      get support_ticket_path(sms_ticket)

      expect(response.body).not_to include("WhatsApp reply window closed")
      expect(response.body).not_to include("disabled=\"disabled\"")
    end
  end

  describe "GET index filters" do
    let!(:participant) do
      Participant.create!(legal_first_name: "Ada", legal_last_name: "Lovelace", email: "ada@example.com", phone: "+15550009999")
    end
    let!(:guardian) do
      Guardian.create!(legal_first_name: "Grace", legal_last_name: "Hopper", email: "grace@example.com", phone: "+15550008888")
    end

    before do
      live_ticket.update!(subject: participant, assigned_to: event_ops, channel: "sms")
      other_ticket.update!(subject: guardian, channel: "signal")
    end

    it "filters by the linked contact's name" do
      sign_in global_admin
      get support_tickets_path, params: { q: "lovel" }

      expect(response.body).to include(live_ticket.phone_number)
      expect(response.body).not_to include(other_ticket.phone_number)
    end

    it "matches guardians as well as participants" do
      sign_in global_admin
      get support_tickets_path, params: { q: "Grace Hopper" }

      expect(response.body).to include(other_ticket.phone_number)
      expect(response.body).not_to include(live_ticket.phone_number)
    end

    it "filters by phone number ignoring formatting" do
      sign_in global_admin
      get support_tickets_path, params: { phone: "(555) 000-2222" }

      expect(response.body).to include(live_ticket.phone_number)
      expect(response.body).not_to include(pending_ticket.phone_number)
    end

    it "filters by channel" do
      sign_in global_admin
      get support_tickets_path, params: { channel: "signal" }

      expect(response.body).to include(other_ticket.phone_number)
      expect(response.body).not_to include(live_ticket.phone_number)
    end

    it "filters by assignee" do
      sign_in global_admin
      get support_tickets_path, params: { assignee: event_ops.id }

      expect(response.body).to include(live_ticket.phone_number)
      expect(response.body).not_to include(other_ticket.phone_number)
    end

    it "filters by unassigned tickets" do
      sign_in global_admin
      get support_tickets_path, params: { assignee: "unassigned" }

      expect(response.body).to include(other_ticket.phone_number)
      expect(response.body).not_to include(live_ticket.phone_number)
    end

    it "filters by status" do
      live_ticket.close!(user: global_admin)

      sign_in global_admin
      get support_tickets_path, params: { status: "closed" }

      expect(response.body).to include(live_ticket.phone_number)
      expect(response.body).not_to include(other_ticket.phone_number)
    end

    it "ignores an assignee that is not a valid id" do
      sign_in global_admin
      get support_tickets_path, params: { assignee: "not-a-uuid" }

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(live_ticket.phone_number)
    end

    it "combines every filter without blowing up" do
      sign_in global_admin
      get support_tickets_path, params: { q: "ada", phone: "555", channel: "sms", assignee: "not-a-uuid", status: "open" }

      expect(response).to have_http_status(:ok)
    end

    it "still scopes filtered results to what the user may see" do
      sign_in event_ops
      get support_tickets_path, params: { channel: "signal" }

      expect(response.body).not_to include(other_ticket.phone_number)
    end
  end

  describe "PATCH bulk_close" do
    it "closes every selected ticket the user may update" do
      sign_in global_admin
      patch bulk_close_support_tickets_path, params: { ticket_ids: [ pending_ticket.id, live_ticket.id ] }

      expect(response).to redirect_to(support_tickets_path)
      expect(pending_ticket.reload).to be_closed
      expect(live_ticket.reload).to be_closed
      expect(flash[:notice]).to eq("Closed 2 tickets.")
    end

    it "skips tickets outside the user's scope" do
      sign_in event_ops
      patch bulk_close_support_tickets_path, params: { ticket_ids: [ live_ticket.id, other_ticket.id ] }

      expect(live_ticket.reload).to be_closed
      expect(other_ticket.reload).to be_open
      expect(flash[:notice]).to eq("Closed 1 ticket.")
    end

    it "denies staff outside their support window" do
      sign_in past_event_admin
      patch bulk_close_support_tickets_path, params: { ticket_ids: [ pending_ticket.id ] }

      expect(pending_ticket.reload).to be_open
    end

    it "tolerates ids that are not valid uuids" do
      sign_in global_admin
      patch bulk_close_support_tickets_path, params: { ticket_ids: [ "", "nope", pending_ticket.id ] }

      expect(pending_ticket.reload).to be_closed
    end

    it "keeps the active filters on the redirect" do
      sign_in global_admin
      patch bulk_close_support_tickets_path, params: { ticket_ids: [ pending_ticket.id ], channel: "whatsapp", status: "open" }

      expect(response).to redirect_to(support_tickets_path(channel: "whatsapp", status: "open"))
    end

    it "audits each closed ticket" do
      sign_in global_admin

      expect {
        patch bulk_close_support_tickets_path, params: { ticket_ids: [ pending_ticket.id, live_ticket.id ] }
      }.to change { AuditLog.where(action: "close", record_type: "Ticket").count }.by(2)
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
