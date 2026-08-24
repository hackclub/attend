require "rails_helper"

RSpec.describe LinksToolbox do
  let(:routes) { Rails.application.routes.url_helpers }
  let(:base) { AttendUrls.attend_base_url }

  def run(action, params = {}, actor:)
    toolbox = described_class.new(params: params.transform_keys(&:to_s))
    allow(toolbox).to receive(:current_user).and_return(actor)
    catch(:halt) { toolbox.public_send(action) }
    toolbox
  end

  # Actions render a JSON string into @_response; errors render plain text.
  def raw(toolbox) = toolbox.instance_variable_get(:@_response)

  def payload(toolbox) = JSON.parse(raw(toolbox)[:content].first[:text], symbolize_names: true)

  def error_text(toolbox) = raw(toolbox)[:content].first[:text]

  describe "the published patterns" do
    # The templates are hand-written so they stay readable; these assertions are
    # what stops them drifting away from the routes they describe.
    it "match the real routes they claim to describe" do
      expected = {
        "public participant profile" => routes.public_profile_path(slug: "slug"),
        "event admin dashboard" => routes.admin_event_dashboard_path(slug: "slug"),
        "event participant list" => routes.admin_event_participants_path(event_slug: "slug"),
        "one participant at one event" => routes.admin_event_participant_path(event_slug: "slug", id: "id"),
        "event incident" => routes.admin_event_incident_path(event_slug: "slug", id: "id"),
        "event message/blast" => routes.admin_event_message_path(event_slug: "slug", id: "id"),
        "event groups" => routes.admin_event_groups_path(event_slug: "slug"),
        "rooming wizard" => routes.admin_event_rooming_wizard_path(event_slug: "slug"),
        "check-in scanner" => routes.scanner_admin_event_scans_path(event_slug: "slug"),
        "travel calendar" => routes.admin_event_travel_path(event_slug: "slug"),
        "support ticket" => routes.support_ticket_path("id"),
        "guardian portal finder" => routes.guardian_portal_center_path
      }

      expected.each do |page, real_path|
        template = described_class::PATTERNS.fetch(page)[:template]
        filled = template.gsub(/\{event_slug\}|\{public_profile_slug\}/, "slug").gsub(/\{\w+\}/, "id")
        expect(filled).to eq(real_path), "#{page}: template #{template} does not match #{real_path}"
      end
    end

    it "names only participant sub-pages that route" do
      described_class::PATTERNS.fetch("participant sub-pages")
      AttendUrls::PARTICIPANT_PAGES.each do |page|
        expect(routes).to respond_to("#{page}_admin_event_participant_path")
      end
    end
  end

  describe "links_participant" do
    let(:admin) { create(:user, global_role: "global_admin") }

    it "returns the admin registration link for each event, keyed by participant_event id" do
      pe = create(:participant_event)

      data = payload(run(:participant, { participant_id: pe.participant_id }, actor: admin))
      registration = data[:registrations].sole

      expect(registration[:participant_event_id]).to eq(pe.id)
      expect(registration[:url]).to eq("#{base}/admin/events/#{pe.event.slug}/participants/#{pe.id}")
      expect(registration[:pages][:medical]).to end_with("/participants/#{pe.id}/medical")
    end

    it "explains that there is no profile link when the participant hasn't opted in" do
      pe = create(:participant_event)

      data = payload(run(:participant, { participant_id: pe.participant_id }, actor: admin))

      expect(data[:public_profile_url]).to be_nil
      expect(data[:public_profile_note]).to include("opt-in")
    end

    it "links the public profile of a participant who enabled one" do
      pe = create(:participant_event)
      pe.participant.update!(public_profile_enabled: true, public_profile_slug: "zoe-h")

      data = payload(run(:participant, { participant_id: pe.participant_id }, actor: admin))

      expect(data[:public_profile_url]).to eq("#{base}/p/zoe-h")
      expect(data[:public_profile_note]).to be_nil
    end

    it "refuses to link a participant from an event the user cannot access" do
      pe = create(:participant_event)
      stranger = create(:user)

      toolbox = run(:participant, { participant_id: pe.participant_id }, actor: stranger)

      expect(raw(toolbox)[:isError]).to be(true)
      expect(error_text(toolbox)).to include("don't have access")
    end
  end
end
