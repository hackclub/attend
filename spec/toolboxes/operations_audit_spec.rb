require "rails_helper"

# Through the real MCP router: tools that run an operation are audited by it,
# by name, and the toolbox's catch-all audit_write! stands down. The
# connection's event allowlist still applies, because operations authorize
# back through ApplicationToolbox#authorize!.
RSpec.describe "MCP tools that run operations", type: :toolbox do
  include ActiveJob::TestHelper

  let(:user) { create(:user, global_role: "global_admin") }
  let(:event) { create(:event, name: "Assemble") }
  let(:other_event) { create(:event, name: "Undercity") }
  let(:participant) { create(:participant, date_of_birth: 15.years.ago.to_date) }
  let!(:participant_event) { create(:participant_event, event: event, participant: participant, status: :in_progress) }
  let(:guardian) { create(:guardian, email: "parent@example.con") }
  let!(:link) { create(:guardian_participant_event, participant_event: participant_event, guardian: guardian) }

  let(:application) do
    Toolchest::OauthApplication.create!(name: "Poke", redirect_uri: "https://poke.example.com/callback")
  end

  let(:token) do
    Toolchest::OauthAccessToken.create_for(
      application: application, resource_owner_id: user.id, scopes: "participants:read participants:write"
    )
  end

  let(:auth) { Toolchest::AuthContext.new(resource_owner: user, scopes: token.scopes_array, token: token) }

  before { Current.reset }
  after { Current.reset }

  it "audits a new note once, without its body" do
    call_tool("notes_create",
      params: { "participant_event_id" => participant_event.id, "body" => "Bringing a sibling." }, as: auth)

    expect(tool_response).to be_success
    log = AuditLog.sole
    expect(log.action).to eq("record_create")
    expect(log.record).to eq(Note.sole)
    expect(log.event).to eq(event)
    expect(log.to_json).not_to include("sibling")
  end

  it "audits a guardian correction once, with the email redacted" do
    call_tool("participant_events_update_guardian",
      params: { "participant_event_id" => participant_event.id, "guardian_participant_event_id" => link.id,
                "email" => "parent@example.com" }, as: auth)

    expect(tool_response).to be_success
    expect(guardian.reload.email).to eq("parent@example.com")
    log = AuditLog.sole
    expect(log.action).to eq("record_update")
    expect(log.record).to eq(guardian)
    expect(log.changed_fields).to eq("email" => "[REDACTED]")
  end

  it "audits a guardian invite resend once, by name" do
    call_tool("participant_events_resend_guardian_invite",
      params: { "participant_event_id" => participant_event.id, "guardian_participant_event_id" => link.id }, as: auth)

    expect(tool_response).to be_success
    expect(AuditLog.sole.action).to eq("resend_guardian_invite")
  end

  # MCP's resend emails the link already out there again; the admin UI's
  # rotates it. Pinned as found.
  it "keeps the guardian's existing link working on a resend" do
    old_token = link.generate_invite_token!

    call_tool("participant_events_resend_guardian_invite",
      params: { "participant_event_id" => participant_event.id, "guardian_participant_event_id" => link.id }, as: auth)

    expect(link.reload.invite_token).to eq(old_token)
    expect(AuditLog.sole.metadata).to include("token_rotated" => false)
  end

  it "holds a guardian correction to event admins" do
    ops = create(:user).tap { |staff| EventRoleAssignment.create!(user: staff, event: event, role: "ops") }
    ops_token = Toolchest::OauthAccessToken.create_for(
      application: application, resource_owner_id: ops.id, scopes: "participants:read participants:write"
    )
    ops_auth = Toolchest::AuthContext.new(resource_owner: ops, scopes: ops_token.scopes_array, token: ops_token)

    call_tool("participant_events_update_guardian",
      params: { "participant_event_id" => participant_event.id, "guardian_participant_event_id" => link.id,
                "legal_first_name" => "Janet" }, as: ops_auth)

    expect(tool_response).to be_error
    expect(guardian.reload.legal_first_name).not_to eq("Janet")
  end

  it "keeps the catch-all hook for tools that don't run an operation" do
    call_tool("participant_events_check_in", params: { "participant_event_id" => participant_event.id }, as: auth)

    expect(tool_response).to be_success
    expect(AuditLog.sole.action).to eq("record_update").or eq("record_create")
    expect(AuditLog.sole.metadata).not_to have_key("operation")
  end

  it "still holds an operation to the connection's event allowlist" do
    McpConnectionSetting.create!(application: application, resource_owner_id: user.id.to_s)
      .narrow_events!([ other_event.id ])

    call_tool("notes_create",
      params: { "participant_event_id" => participant_event.id, "body" => "Bringing a sibling." }, as: auth)

    expect(tool_response).to be_error
    expect(tool_response).to include_text("scoped to Undercity")
    expect(Note.count).to eq(0)
    expect(AuditLog.count).to eq(0)
  end
end
