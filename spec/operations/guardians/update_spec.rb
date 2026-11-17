require "rails_helper"

RSpec.describe Guardians::Update do
  let(:event) { create(:event) }
  let(:participant) { create(:participant, date_of_birth: 15.years.ago.to_date) }
  let(:participant_event) { create(:participant_event, event: event, participant: participant, status: :awaiting_guardian) }
  let(:guardian) { create(:guardian, :with_address, email: "parent@example.con") }
  let!(:link) { create(:guardian_participant_event, participant_event: participant_event, guardian: guardian) }
  let(:global_admin) { create(:user, global_role: "global_admin") }

  def staff(role)
    create(:user).tap { |user| EventRoleAssignment.create!(user: user, event: event, role: role) }
  end

  def context_for(user, surface:)
    Operation::Context.new(surface: surface, user: user, event: event, pii_scope: surface == :mcp ? :any : :event)
  end

  def update(context, attributes, reference: link)
    described_class.call(context, participant_event: participant_event, guardian_participant_event: reference,
      attributes: attributes)
  end

  around { |example| Current.set(event: event) { example.run } }

  it "corrects the email, kills the link sent to the old address, and audits it redacted" do
    old_token = link.generate_invite_token!
    link.update!(invite_token_sent_at: 1.day.ago)

    result = update(context_for(global_admin, surface: :html), { email: "parent@example.com", city: "Shelbyville" })

    expect(result).to be_success
    expect(guardian.reload).to have_attributes(email: "parent@example.com", city: "Shelbyville")
    expect { GuardianParticipantEvent.find_by_invite_token!(old_token) }.to raise_error(ActiveRecord::RecordNotFound)

    log = AuditLog.sole
    expect(log.action).to eq("record_update")
    expect(log.record).to eq(guardian)
    expect(log.changed_fields).to eq("email" => "[REDACTED]", "city" => "[REDACTED]")
    expect(log.metadata).to include("invite_revoked" => true, "guardian_participant_event_id" => link.id)
    expect(log.to_json).not_to include("parent@example", "Shelbyville", "Springfield")
  end

  it "leaves the link alone when the email didn't change or the guardian has finished" do
    token = link.generate_invite_token!

    update(context_for(global_admin, surface: :html), { legal_first_name: "Janet" })
    expect(GuardianParticipantEvent.find_by_invite_token!(token)).to eq(link)

    link.update!(status: :completed, completed_at: Time.current)
    update(context_for(global_admin, surface: :html), { email: "parent@example.com" })
    expect(link.reload.invite_token_digest).to be_present
  end

  it "accepts the link's id, looked up inside the registration" do
    other_link = create(:guardian_participant_event, participant_event: create(:participant_event, event: event))

    expect(update(context_for(global_admin, surface: :mcp), { legal_first_name: "Janet" }, reference: link.id)).to be_success
    expect { update(context_for(global_admin, surface: :mcp), { legal_first_name: "Janet" }, reference: other_link.id) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  it "refuses a phone that is also the participant's" do
    participant.update!(phone: "+12025550123")

    result = update(context_for(global_admin, surface: :html), { phone: "+1 202 555 0123" })

    expect(result.code).to eq(:phone_matches_participant)
    expect(result.record.errors[:phone]).to be_present
    expect(guardian.reload.phone).to eq("+12025559876")
  end

  it "comes back invalid when the guardian can't be saved" do
    result = update(context_for(global_admin, surface: :html), { email: participant.email })

    expect(result.code).to eq(:invalid)
    expect(result.record).to eq(guardian)
    expect(AuditLog.count).to eq(0)
  end

  # The two surfaces hold this to different bars today. Pinned as found, so a
  # change to either is a decision rather than an accident.
  describe "who may, by surface" do
    it "lets ops through the admin UI, which has no policy check, but not through MCP" do
      ops = staff("ops")

      expect(update(context_for(ops, surface: :html), { legal_first_name: "Janet" })).to be_success
      expect { update(context_for(ops, surface: :mcp), { legal_first_name: "Janice" }) }
        .to raise_error(Pundit::NotAuthorizedError)
      expect(guardian.reload.legal_first_name).to eq("Janet")
    end

    it "lets an event admin through both" do
      admin = staff("event_admin")

      expect(update(context_for(admin, surface: :html), { legal_first_name: "Janet" })).to be_success
      expect(update(context_for(admin, surface: :mcp), { legal_first_name: "Janice" })).to be_success
    end

    it "refuses a role that can't see PII on this event through the admin UI" do
      result = update(context_for(staff("limited"), surface: :html), { legal_first_name: "Janet" })

      expect(result.code).to eq(:pii_restricted)
      expect(guardian.reload.legal_first_name).to eq("Jane")
    end
  end
end
