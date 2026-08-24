require "rails_helper"

# Per-connection MCP restrictions. Everything here only tightens: widening
# means re-authorizing the client through the consent screen.
RSpec.describe McpConnectionSetting do
  let(:user) { create(:user) }
  let(:application) do
    Toolchest::OauthApplication.create!(
      name: "Poke", redirect_uri: "https://poke.example.com/callback"
    )
  end
  let(:settings) do
    described_class.create!(application: application, resource_owner_id: user.id.to_s)
  end
  let(:assemble) { create(:event, name: "Assemble") }
  let(:undercity) { create(:event, name: "Undercity") }

  it "defaults to every event and no anonymization" do
    expect(settings).to be_all_events
    expect(settings).not_to be_anonymize
    expect(settings.permitted_event_ids).to be_nil
    expect(settings.permits_event?(assemble)).to be(true)
  end

  it "finds the row for an application and user" do
    settings

    expect(described_class.for(application.id, user)).to eq(settings)
    expect(described_class.for(application.id, create(:user))).to be_nil
    expect(described_class.for(nil, user)).to be_nil
  end

  describe "#narrow_events!" do
    it "restricts an unrestricted connection to the named events" do
      expect(settings.narrow_events!([ assemble.id ])).to be(true)

      expect(settings.reload).not_to be_all_events
      expect(settings.permitted_event_ids).to contain_exactly(assemble.id)
      expect(settings.permits_event?(assemble)).to be(true)
      expect(settings.permits_event?(undercity)).to be(false)
    end

    it "ignores events the connection cannot already reach" do
      settings.narrow_events!([ assemble.id ])

      settings.narrow_events!([ assemble.id, undercity.id ])

      expect(settings.reload.permitted_event_ids).to contain_exactly(assemble.id)
    end

    it "refuses to narrow to nothing" do
      settings.narrow_events!([ assemble.id ])

      expect(settings.narrow_events!([ undercity.id ])).to be(false)
      expect(settings.narrow_events!([])).to be(false)
      expect(settings.reload.permitted_event_ids).to contain_exactly(assemble.id)
    end

    it "drops events that are taken away" do
      settings.narrow_events!([ assemble.id, undercity.id ])

      settings.narrow_events!([ undercity.id ])

      expect(settings.reload.permitted_event_ids).to contain_exactly(undercity.id)
    end
  end

  describe "#anonymize!" do
    it "records when and where it was turned on" do
      settings.anonymize!(:mcp)

      expect(settings.reload).to be_anonymize
      expect(settings.anonymize_enabled_by).to eq("mcp")
      expect(settings.anonymize_enabled_at).to be_within(5.seconds).of(Time.current)
    end

    it "leaves an already-anonymized connection alone" do
      settings.anonymize!(:consent)
      enabled_at = settings.reload.anonymize_enabled_at

      settings.anonymize!(:mcp)

      expect(settings.reload.anonymize_enabled_by).to eq("consent")
      expect(settings.anonymize_enabled_at).to eq(enabled_at)
    end
  end

  it "refuses to be event-restricted with no events" do
    settings.all_events = false

    expect(settings).not_to be_valid
    expect(settings.errors.full_messages.join).to include("at least one event")
  end
end
