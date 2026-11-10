require "rails_helper"

# The support-inbox tools: guardian corrections, waiver re-issue, identity
# fixes, and change-request review. Driven directly with current_user stubbed,
# like the other toolbox specs.
RSpec.describe "registration support MCP tools" do
  include ActiveJob::TestHelper

  let(:admin) { create(:user, global_role: :global_admin) }
  let(:event) { create(:event) }
  let(:participant) { create(:participant, date_of_birth: 15.years.ago.to_date) }
  let(:participant_event) { create(:participant_event, event: event, participant: participant, status: :awaiting_guardian) }
  let(:guardian) { create(:guardian, email: "parent@example.con") }
  let!(:guardian_link) do
    create(:guardian_participant_event, participant_event: participant_event, guardian: guardian, is_primary_guardian: true)
  end

  before { Current.reset }
  after { Current.reset }

  # Runs a tool action and returns [rendered json, halt error message or nil].
  # halt renders its error and throws :halt (with no value) for the Toolchest
  # dispatch to catch; calling the action directly means catching it here.
  def run_tool(klass, action, actor: admin, **params)
    toolbox = klass.new(params: params.stringify_keys)
    @last_toolbox = toolbox
    allow(toolbox).to receive(:current_user).and_return(actor)
    allow(toolbox).to receive(:authorize!).and_return(true)
    rendered = nil
    error = nil
    allow(toolbox).to receive(:render) { |json:| rendered = json }
    allow(toolbox).to receive(:render_error) { |message| error = message }
    completed = false
    catch(:halt) do
      toolbox.public_send(action)
      completed = true
    end
    [ rendered, completed ? nil : (error || "halted") ]
  end

  describe "ParticipantEventsToolbox#update_guardian" do
    it "corrects a mistyped guardian email and clears the invite stamp so the next invite is fresh" do
      json, = run_tool(ParticipantEventsToolbox, :update_guardian,
        participant_event_id: participant_event.id,
        guardian_participant_event_id: guardian_link.id,
        email: "parent@example.com")

      expect(guardian.reload.email).to eq("parent@example.com")
      expect(guardian_link.reload.invite_token_sent_at).to be_nil
      expect(json[:also_linked_to_other_registrations]).to eq(0)
    end

    it "reports when the guardian is shared with a sibling's registration" do
      sibling_event = create(:participant_event, event: event)
      create(:guardian_participant_event, participant_event: sibling_event, guardian: guardian)

      json, = run_tool(ParticipantEventsToolbox, :update_guardian,
        participant_event_id: participant_event.id,
        guardian_participant_event_id: guardian_link.id,
        email: "parent@example.com")

      expect(json[:also_linked_to_other_registrations]).to eq(1)
    end

    it "refuses an email that matches the participant's" do
      expect {
        run_tool(ParticipantEventsToolbox, :update_guardian,
          participant_event_id: participant_event.id,
          guardian_participant_event_id: guardian_link.id,
          email: participant.email)
      }.to raise_error(ActiveRecord::RecordInvalid)

      expect(guardian.reload.email).to eq("parent@example.con")
    end

    it "is refused for roles that can't see guardian contact details" do
      ops = create(:user)
      allow(ops).to receive(:can_view_participant_pii?).and_return(false)

      _, halted = run_tool(ParticipantEventsToolbox, :update_guardian,
        participant_event_id: participant_event.id, guardian_participant_event_id: guardian_link.id,
        email: "parent@example.com", actor: ops)

      expect(halted).to be_present
      expect(guardian.reload.email).to eq("parent@example.con")
    end
  end

  describe "ParticipantEventsToolbox#resend_guardian_invite" do
    it "emails the guardian their invite" do
      expect {
        run_tool(ParticipantEventsToolbox, :resend_guardian_invite,
          participant_event_id: participant_event.id, guardian_participant_event_id: guardian_link.id)
      }.to have_enqueued_mail(GuardianMailer, :invitation)
    end

    it "refuses to send to a bouncing address" do
      guardian.update_column(:email_undeliverable_at, Time.current)

      expect {
        _, halted = run_tool(ParticipantEventsToolbox, :resend_guardian_invite,
          participant_event_id: participant_event.id, guardian_participant_event_id: guardian_link.id)
        expect(halted).to be_present
      }.not_to have_enqueued_mail(GuardianMailer, :invitation)
    end
  end

  describe "ParticipantEventsToolbox#reset_waiver" do
    it "re-issues a delegated or stuck waiver and emails the guardian" do
      guardian_link.update!(status: :completed)
      consent = create(:consent, participant_event: participant_event, status: :sent,
        docuseal_envelope_id: "123", sent_at: 1.day.ago)

      expect {
        json, = run_tool(ParticipantEventsToolbox, :reset_waiver,
          participant_event_id: participant_event.id, waiver_type: "waiver")
        expect(json[:emailed]).to eq("guardian")
      }.to have_enqueued_mail(GuardianMailer, :waiver_reset)

      expect(consent.reload).to have_attributes(status: "pending", docuseal_envelope_id: nil, sent_at: nil)
      # What audit_write! logs against: the reset consent, with its changes intact.
      expect(@last_toolbox.send(:find_changed_record)).to eq(consent)
      expect(guardian_link.reload.status).to eq("in_progress")
    end

    it "says so when there's no waiver to reset" do
      _, halted = run_tool(ParticipantEventsToolbox, :reset_waiver,
        participant_event_id: participant_event.id, waiver_type: "freedom_waiver")

      expect(halted).to be_present
    end
  end

  describe "ParticipantsToolbox#update" do
    it "corrects a date of birth and legal name" do
      run_tool(ParticipantsToolbox, :update,
        participant_id: participant.id, date_of_birth: "2011-02-15", legal_first_name: "Corrected")

      expect(participant.reload).to have_attributes(date_of_birth: Date.new(2011, 2, 15), legal_first_name: "Corrected")
    end

    it "ignores a date of birth from a role that can't see it" do
      ops = create(:user)
      allow(ops).to receive(:can_view_participant_pii?).and_return(false)
      allow(ops).to receive(:global_admin?).and_return(true)
      original = participant.date_of_birth

      run_tool(ParticipantsToolbox, :update,
        participant_id: participant.id, date_of_birth: "2011-02-15", actor: ops)

      expect(participant.reload.date_of_birth).to eq(original)
    end
  end

  describe ChangeRequestsToolbox do
    let(:requester) { create(:user) }
    let(:change_request) do
      RegistrationChangeRequest.create!(
        participant_event: participant_event,
        requested_by: requester,
        kind: :guardian,
        staff_audience: :event_admin,
        requested_changes: {
          "legal_first_name" => "Pat", "legal_last_name" => "Parent",
          "email" => "parent@example.com", "relationship" => "parent"
        }
      )
    end

    it "lists an event's pending requests with their review link" do
      change_request

      json, = run_tool(described_class, :index, event_id: event.id)

      expect(json[:total]).to eq(1)
      expect(json[:change_requests].sole).to include(kind: "guardian", status: "pending")
      expect(json[:change_requests].sole[:url]).to include("/registration_change_requests/#{change_request.id}")
    end

    it "approves a guardian replacement through the same service as the admin UI" do
      json, = run_tool(described_class, :approve, change_request_id: change_request.id)

      expect(json[:result]).to eq(:approved)
      expect(@last_toolbox.send(:find_changed_record)).to eq(change_request)
      expect(participant_event.reload.guardian_participant_events.sole.guardian.email).to eq("parent@example.com")
    end

    it "refuses to approve a request twice" do
      run_tool(described_class, :approve, change_request_id: change_request.id)
      _, halted = run_tool(described_class, :approve, change_request_id: change_request.id)

      expect(halted).to be_present
    end

    it "sends a request back for more information" do
      expect {
        run_tool(described_class, :request_follow_up,
          change_request_id: change_request.id, staff_response: "Which address should we use?")
      }.to have_enqueued_mail(RegistrationCorrectionMailer, :participant_follow_up)

      expect(change_request.reload).to have_attributes(status: "follow_up_needed", resolved_by: admin)
    end
  end
end
