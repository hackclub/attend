require "rails_helper"

RSpec.describe Guardians::ResendInvite do
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }
  let!(:link) { create(:guardian_participant_event, participant_event: participant_event) }
  let(:global_admin) { create(:user, global_role: "global_admin") }

  def context_for(user, surface:)
    Operation::Context.new(surface: surface, user: user, event: event)
  end

  def resend(context, reference: link)
    described_class.call(context, participant_event: participant_event, guardian_participant_event: reference)
  end

  around { |example| Current.set(event: event) { example.run } }

  it "emails the invite and audits it by name, without the token" do
    token = link.generate_invite_token!
    link.update!(invite_token_sent_at: 1.day.ago)

    expect { resend(context_for(global_admin, surface: :html)) }.to have_enqueued_mail(GuardianMailer, :invitation)

    log = AuditLog.sole
    expect(log.action).to eq("resend_guardian_invite")
    expect(log.record).to eq(link)
    expect(log.changed_fields.keys).to eq([ "invite_token_sent_at" ])
    expect(log.metadata).to include("participant_event_id" => participant_event.id, "token_rotated" => true)
    expect(log.to_json).not_to include(token)
  end

  # The surfaces treat the link already out there differently today. Pinned as
  # found, so a change to either is a decision rather than an accident.
  describe "what happens to the old link, by surface" do
    it "dies on a resend from the admin UI" do
      token = link.generate_invite_token!

      resend(context_for(global_admin, surface: :html))

      expect { GuardianParticipantEvent.find_by_invite_token!(token) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "keeps working on a resend from MCP, which only clears the sent-at stamp" do
      token = link.generate_invite_token!
      link.update!(invite_token_sent_at: 1.day.ago)

      resend(context_for(global_admin, surface: :mcp))

      expect(link.reload.invite_token_sent_at).to be_nil
      expect(link.invite_token).to eq(token)
      expect(AuditLog.sole.metadata).to include("token_rotated" => false)
    end

    it "audits an MCP resend even when there was no sent-at stamp to clear" do
      link.update!(invite_token_sent_at: nil)

      resend(context_for(global_admin, surface: :mcp))

      expect(AuditLog.sole.action).to eq("resend_guardian_invite")
    end
  end

  it "sends nothing when the run is rolled back" do
    allow(AuditLog).to receive(:log!).and_raise(ActiveRecord::StatementInvalid, "audit_logs is unavailable")

    expect {
      expect { resend(context_for(global_admin, surface: :html)) }.to raise_error(ActiveRecord::StatementInvalid)
    }.not_to have_enqueued_mail(GuardianMailer, :invitation)
  end

  it "is held to event admins" do
    ops = create(:user).tap { |user| EventRoleAssignment.create!(user: user, event: event, role: "ops") }

    expect { resend(context_for(ops, surface: :html)) }.to raise_error(Pundit::NotAuthorizedError)
    expect(AuditLog.count).to eq(0)
  end

  it "refuses while the event has guardian invites locked" do
    allow_any_instance_of(Event).to receive(:guardian_invites_locked?).and_return(true)

    expect {
      expect(resend(context_for(global_admin, surface: :html)).code).to eq(:invites_locked)
    }.not_to have_enqueued_mail(GuardianMailer, :invitation)
  end

  it "refuses a bouncing address" do
    link.guardian.update_column(:email_undeliverable_at, Time.current)

    expect {
      expect(resend(context_for(global_admin, surface: :mcp)).code).to eq(:email_undeliverable)
    }.not_to have_enqueued_mail(GuardianMailer, :invitation)
    expect(AuditLog.count).to eq(0)
  end
end
