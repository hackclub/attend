require "rails_helper"

# End-to-end through the MCP router: per-connection event scoping and
# anonymization, enforced for whichever tool gets called rather than per
# serializer. See McpConnectionSetting and Mcp::ResponseFilter.
RSpec.describe "MCP connection settings", type: :toolbox do
  let(:user) { create(:user) }
  let(:assemble) { create(:event, name: "Assemble") }
  let(:undercity) { create(:event, name: "Undercity") }

  let(:application) do
    Toolchest::OauthApplication.create!(
      name: "Poke", redirect_uri: "https://poke.example.com/callback"
    )
  end

  let(:token) do
    Toolchest::OauthAccessToken.create_for(
      application: application,
      resource_owner_id: user.id,
      scopes: "events:read participants:read participants:write groups:read"
    )
  end

  let(:auth) do
    Toolchest::AuthContext.new(resource_owner: user, scopes: token.scopes_array, token: token)
  end

  let(:ticket_token) do
    Toolchest::OauthAccessToken.create_for(
      application: application, resource_owner_id: user.id, scopes: "tickets:read"
    )
  end

  let(:ticket_auth) do
    Toolchest::AuthContext.new(resource_owner: user, scopes: ticket_token.scopes_array, token: ticket_token)
  end

  let(:settings) do
    McpConnectionSetting.create!(application: application, resource_owner_id: user.id.to_s)
  end

  before do
    create(:event_role_assignment, user: user, event: assemble, role: "event_admin")
    create(:event_role_assignment, user: user, event: undercity, role: "event_admin")
  end

  def json = JSON.parse(tool_response.text)

  describe "event scoping" do
    it "lists every accessible event when the connection is unrestricted" do
      settings

      call_tool("events_index", as: auth)

      expect(tool_response).to be_success
      expect(json["events"].map { |e| e["name"] }).to contain_exactly("Assemble", "Undercity")
    end

    it "lists only the connection's events when it is restricted" do
      settings.narrow_events!([ assemble.id ])

      call_tool("events_index", as: auth)

      expect(json["events"].map { |e| e["name"] }).to eq([ "Assemble" ])
    end

    it "refuses an event outside the connection's scope, and says who can change it" do
      settings.narrow_events!([ assemble.id ])

      call_tool("events_show", params: { "event_id" => undercity.id }, as: auth)

      expect(tool_response).to be_error
      expect(tool_response).to include_text("scoped to Assemble")
      expect(tool_response).to include_text("Profile → Connections")
    end

    it "hides registrations in out-of-scope events" do
      settings.narrow_events!([ assemble.id ])
      participant = create(:participant, legal_first_name: "Kim", legal_last_name: "Doe")
      create(:participant_event, participant: participant, event: undercity)

      call_tool("participants_search", params: { "query" => "kim" }, as: auth)

      expect(json["participants"]).to be_empty
    end

    it "refuses a record that isn't linked to any event" do
      settings.narrow_events!([ assemble.id ])
      ticket = Ticket.create!(channel: "sms", phone_number: "+14155550101", status: "open")

      call_tool("tickets_show", params: { "ticket_id" => ticket.id }, as: ticket_auth)

      expect(tool_response).to be_error
      expect(tool_response).to include_text("isn't linked to any event")
    end

    it "still refuses events the user has no role on at all" do
      other = create(:event, name: "Elsewhere")
      settings

      call_tool("events_show", params: { "event_id" => other.id }, as: auth)

      expect(tool_response).to be_error
      expect(tool_response).to include_text("You don't have access to Elsewhere")
    end
  end

  describe "anonymization" do
    let(:participant) do
      create(:participant, legal_first_name: "Kim", legal_last_name: "Doe",
                           email: "kim@example.com", phone: "+1 415 555 0100")
    end

    before { create(:participant_event, participant: participant, event: assemble) }

    it "returns full detail when the connection is not anonymized" do
      settings

      call_tool("participants_search", params: { "query" => "kim" }, as: auth)

      person = json["participants"].sole
      expect(person["name"]).to eq("Kim Doe")
      expect(person["email"]).to eq("kim@example.com")
    end

    it "returns initials and strips contact details when it is" do
      settings.anonymize!(:consent)

      call_tool("participants_search", params: { "query" => "kim" }, as: auth)

      person = json["participants"].sole
      expect(person["name"]).to eq("K.D.")
      expect(person["legal_name"]).to eq("K.D.")
      expect(person["email"]).to eq("[redacted]")
    end

    it "still returns non-identifying event data" do
      settings.anonymize!(:consent)

      call_tool("events_show", params: { "event_id" => assemble.id }, as: auth)

      expect(tool_response).to be_success
      expect(json["name"]).to eq("Assemble")
    end

    it "refuses write tools and explains how to lift it" do
      settings.anonymize!(:consent)

      call_tool("participants_update",
        params: { "participant_id" => participant.id, "preferred_name" => "Kimmy" }, as: auth)

      expect(tool_response).to be_error
      expect(tool_response).to include_text("anonymized")
      expect(tool_response).to include_text("Profile → Connections")
      expect(participant.reload.preferred_name).not_to eq("Kimmy")
    end
  end

  describe "me_anonymize" do
    it "turns anonymization on for the connection" do
      settings

      call_tool("me_anonymize", params: { "confirm" => true }, as: auth)

      expect(tool_response).to be_success
      expect(json["changed"]).to be(true)
      expect(settings.reload).to be_anonymize
      expect(settings.anonymize_enabled_by).to eq("mcp")
    end

    it "creates settings for a connection that predates them" do
      expect { call_tool("me_anonymize", params: { "confirm" => true }, as: auth) }
        .to change(McpConnectionSetting, :count).by(1)

      expect(McpConnectionSetting.for(application.id, user)).to be_anonymize
    end

    it "needs confirmation" do
      settings

      call_tool("me_anonymize", params: { "confirm" => false }, as: auth)

      expect(tool_response).to be_error
      expect(settings.reload).not_to be_anonymize
    end

    # It's the one write an anonymized connection may still make — otherwise the
    # read-only rule would stop the ratchet from being re-affirmed.
    it "stays callable on an already-anonymized connection and cannot turn it off" do
      settings.anonymize!(:consent)

      call_tool("me_anonymize", params: { "confirm" => true }, as: auth)

      expect(tool_response).to be_success
      expect(json["changed"]).to be(false)
      expect(settings.reload).to be_anonymize
    end

    it "reports the connection's restrictions from me_show" do
      settings.narrow_events!([ assemble.id ])
      settings.anonymize!(:dashboard)

      call_tool("me_show", as: auth)

      expect(json["connection"]).to include(
        "anonymized" => true, "writes_allowed" => false, "event_scope" => [ "Assemble" ]
      )
    end
  end
end
