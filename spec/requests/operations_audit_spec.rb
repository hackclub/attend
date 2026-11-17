require "rails_helper"

# Writes that go through app/operations are audited by the operation, by name.
# Each surface's catch-all hook (log_admin_action, audit_api_change!) has to
# stand down for them, and has to keep working for everything else.
RSpec.describe "Operation audit rows", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:participant) { create(:participant, date_of_birth: 15.years.ago.to_date) }
  let!(:participant_event) { create(:participant_event, event: event, participant: participant, status: :in_progress) }
  let(:guardian) { create(:guardian, :with_address) }
  let!(:link) { create(:guardian_participant_event, participant_event: participant_event, guardian: guardian) }
  let(:admin) { create(:user, global_role: "global_admin") }

  describe "the admin UI" do
    before do
      sign_in admin
      # Warm-up GET: the first POST after sign-in otherwise audit-logs the user.
      get admin_event_participant_path(event, participant_event)
    end

    it "audits a new note once, without its body" do
      post admin_event_participant_notes_path(event, participant_event),
        params: { note: { body: "Needs a quiet room.", note_type: "ops" } }

      expect(flash[:notice]).to eq("Note added successfully.")
      log = AuditLog.sole
      expect(log.action).to eq("record_create")
      expect(log.record).to eq(Note.sole)
      expect(log.to_json).not_to include("quiet room")
    end

    it "audits a guardian correction once, on the guardian, with the PII redacted" do
      patch admin_event_participant_guardian_path(event, participant_event, link),
        params: { guardian: { legal_first_name: "Janet", legal_last_name: guardian.legal_last_name,
                              email: "corrected@example.com", phone: guardian.phone, city: "Shelbyville" } }

      expect(response).to redirect_to(admin_event_participant_path(event, participant_event))
      expect(guardian.reload).to have_attributes(email: "corrected@example.com", city: "Shelbyville")

      log = AuditLog.sole
      expect(log.action).to eq("record_update")
      expect(log.record).to eq(guardian)
      expect(log.changed_fields).to include("email" => "[REDACTED]", "city" => "[REDACTED]", "legal_first_name" => %w[Jane Janet])
      expect(log.to_json).not_to include("corrected@example.com", "Shelbyville")
    end

    it "falls back to the catch-all row when the operation's own audit write fails" do
      allow(Rails.env).to receive(:local?).and_return(false)
      attempts = 0
      allow(AuditLog).to receive(:log!).and_wrap_original do |original, **arguments|
        attempts += 1
        raise ActiveRecord::StatementInvalid, "audit_logs is unavailable" if attempts == 1

        original.call(**arguments)
      end

      patch admin_event_participant_guardian_path(event, participant_event, link),
        params: { guardian: { legal_first_name: "Janet", city: "Shelbyville" } }

      expect(guardian.reload).to have_attributes(legal_first_name: "Janet", city: "Shelbyville")
      log = AuditLog.sole
      expect(log.record).to eq(guardian)
      expect(log.metadata).to include("controller" => "guardians")
      expect(log.metadata).not_to have_key("operation")
      expect(log.changed_fields).to include("city" => "[REDACTED]")
      expect(log.to_json).not_to include("Shelbyville")
    end

    it "re-renders the form when the guardian's phone is the participant's" do
      participant.update!(phone: "+12025550123")

      patch admin_event_participant_guardian_path(event, participant_event, link),
        params: { guardian: { phone: "+12025550123" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(guardian.reload.phone).to eq("+12025559876")
    end

    it "audits a guardian invite resend once, by name" do
      post resend_guardian_invite_admin_event_participant_path(event, participant_event),
        params: { guardian_participant_event_id: link.id }

      expect(flash[:notice]).to eq("Guardian invite resent to #{guardian.email}.")
      log = AuditLog.sole
      expect(log.action).to eq("resend_guardian_invite")
      expect(log.metadata).to include("token_rotated" => true)
    end

    it "redacts registry PII from rows the catch-all hook writes too" do
      patch admin_event_participant_path(event, participant_event),
        params: { participant: { date_of_birth: "2010-02-03", tshirt_size: "L" } }

      log = AuditLog.where(record: participant).sole
      expect(log.action).to eq("record_update")
      expect(log.changed_fields["date_of_birth"]).to eq("[REDACTED]")
      expect(log.changed_fields["tshirt_size"]).to be_an(Array)
      expect(log.to_json).not_to include("2010-02-03")
    end

    it "redacts the address fields Rails' parameter filter doesn't name from the catch-all row's params" do
      patch admin_event_participant_path(event, participant_event),
        params: { participant: { tshirt_size: "L", city: "Shelbyville", state: "VT", postal_code: "05001",
                                 country_of_residence: "US" } }

      log = AuditLog.where(record: participant).sole
      expect(log.metadata.dig("params", "participant")).to include(
        "tshirt_size" => "L", "city" => "[REDACTED]", "state" => "[REDACTED]",
        "postal_code" => "[REDACTED]", "country_of_residence" => "[REDACTED]"
      )
      expect(log.to_json).not_to include("Shelbyville", "05001")
    end
  end

  describe "the API" do
    let(:headers) { { "Authorization" => "Bearer #{MobileToken.generate_for(admin).token}" } }

    it "audits a new note, which it never used to" do
      post "/api/v1/events/#{event.id}/participants/#{participant_event.id}/notes",
        params: { content: "Collected by an aunt." }, headers: headers

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body).dig("note", "content")).to eq("Collected by an aunt.")

      log = AuditLog.sole
      expect(log.action).to eq("record_create")
      expect(log.record).to eq(Note.sole)
      expect(log.actor).to eq(admin)
      expect(log.event).to eq(event)
      expect(log.metadata).to include("source" => "api", "surface" => "api", "operation" => "Notes::Create")
      expect(log.to_json).not_to include("aunt")
    end

    it "keeps the restricted-note refusal and its wording" do
      ops = create(:user).tap { |user| EventRoleAssignment.create!(user: user, event: event, role: "ops") }

      post "/api/v1/events/#{event.id}/participants/#{participant_event.id}/notes",
        params: { content: "Sensitive.", sensitivity: "restricted" },
        headers: { "Authorization" => "Bearer #{MobileToken.generate_for(ops).token}" }

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)).to eq("error" => "Only event admins and safeguarding leads can add restricted notes")
      expect(AuditLog.count).to eq(0)
    end

    # audit_api_change! is opt-in, so nothing calls it for a record an
    # operation handles today; this is the guard for when something does.
    it "won't audit a record again once an operation has" do
      controller = Api::V1::ParticipantsController.new
      controller.request = ActionDispatch::TestRequest.create
      controller.instance_variable_set(:@event, event)
      allow(controller).to receive_messages(current_user: admin, api_key_request?: false)

      note = Notes::Create.call(controller.send(:operation_context), participant_event: participant_event,
        attributes: { body: "Arriving late.", note_type: "ops" }).value
      controller.send(:audit_api_change!, :record_update, note)
      controller.send(:audit_api_change!, :record_update, participant, changed_fields: {})

      expect(AuditLog.where(record: note).sole.action).to eq("record_create")
      expect(AuditLog.where(record: participant)).to exist
    end
  end
end
