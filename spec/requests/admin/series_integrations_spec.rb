require "rails_helper"

RSpec.describe "Admin::SeriesIntegrations", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:series) { create(:event_series, name: "Sunbeam", slug: "sunbeam-integrations") }
  let!(:sub_event) { create(:event, event_series: series, slug: "sunbeam-one") }

  let(:owner) do
    User.create!(email: "owner-integrations@example.com", name: "Owner").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
    end
  end
  let(:organizer) do
    User.create!(email: "organizer-integrations@example.com", name: "Organizer").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "organizer")
    end
  end

  # Whether the server holds a vote.hackclub.com key. Without one the page
  # still has to render — it is where an organizer goes to find that out.
  let(:configured) { false }

  before do
    allow_any_instance_of(Vote::Client).to receive(:configured?).and_return(configured)
  end

  describe "GET" do
    it "tells an owner when no vote.hackclub.com key is configured on the server" do
      sign_in owner

      get admin_series_integrations_path(series)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No vote.hackclub.com API key is configured")
    end

    context "with a key configured" do
      let(:configured) { true }

      it "lists the series' events with a button each" do
        sign_in owner

        get admin_series_integrations_path(series)

        expect(response.body).to include("vote.hackclub.com")
        expect(response.body).to include(sub_event.name)
        expect(response.body).to include("Create gallery")
      end

      it "shows an existing gallery instead of offering to create one" do
        sub_event.link_vote_event!(
          "id" => "vote-evt-1",
          "slug" => sub_event.slug,
          "adminUrl" => "https://vote.hackclub.com/admin/vote-evt-1",
          "galleryUrl" => "https://vote.hackclub.com/vote-evt-1"
        )
        sign_in owner

        get admin_series_integrations_path(series)

        expect(response.body).to include("https://vote.hackclub.com/vote-evt-1")
        expect(response.body).to include("Linked")
        expect(response.body).not_to include("Create gallery")
      end

      # The URLs come back from vote.hackclub.com and we store what it sends, so
      # a `javascript:` one must never end up in an href.
      it "refuses to link a stored URL that is not http(s)" do
        sub_event.link_vote_event!(
          "id" => "vote-evt-1",
          "slug" => sub_event.slug,
          "adminUrl" => "javascript:alert(document.cookie)",
          "galleryUrl" => "javascript:alert(1)"
        )
        sign_in owner

        get admin_series_integrations_path(series)

        expect(response.body).to include("Linked")
        expect(response.body).not_to include("javascript:")
        expect(response.body).not_to include("View gallery")
        expect(response.body).not_to include(">Manage<")
      end
    end

    it "keeps a series organizer out — creating a gallery publishes the event elsewhere" do
      sign_in organizer

      get admin_series_integrations_path(series)

      expect(response).to redirect_to(admin_series_path(series))
      expect(flash[:alert]).to match(/Only series owners/)
    end
  end

  describe "POST create_vote_event" do
    let(:vote_client) { instance_double(Vote::Client, configured?: true) }

    let(:vote_body) do
      {
        "id" => "vote-evt-1",
        "slug" => sub_event.slug,
        "adminUrl" => "https://vote.hackclub.com/admin/vote-evt-1",
        "galleryUrl" => "https://vote.hackclub.com/vote-evt-1"
      }
    end

    before { allow(Vote::Client).to receive(:new).and_return(vote_client) }

    it "creates the gallery for one of the series' events and comes back here" do
      allow(vote_client).to receive(:find_event).with(sub_event.slug).and_return(vote_body)
      sign_in owner

      post create_vote_event_admin_series_integrations_path(series, event_id: sub_event.slug)

      expect(response).to redirect_to(admin_series_integrations_path(series))
      expect(flash[:notice]).to include(sub_event.name)
      expect(sub_event.reload.vote_event_id).to eq("vote-evt-1")
    end

    # The event is the audited record here, and it needs to be the current one
    # or the row lands with a null event_id and hides from non-global admins.
    it "audit-logs against the event, not the series" do
      allow(vote_client).to receive(:find_event).and_return(vote_body)
      sign_in owner
      get admin_series_integrations_path(series)

      post create_vote_event_admin_series_integrations_path(series, event_id: sub_event.slug)

      log = AuditLog.find_by!(action: "create_vote_event")
      expect(log.record).to eq(sub_event)
      expect(log.event).to eq(sub_event)
      expect(log.actor).to eq(owner)
    end

    it "explains itself when the event has no artwork yet" do
      allow(vote_client).to receive(:find_event).and_return(nil)
      allow(vote_client).to receive(:create_event)
      sign_in owner

      post create_vote_event_admin_series_integrations_path(series, event_id: sub_event.slug)

      expect(flash[:alert]).to include("needs both a logo and a banner")
      expect(vote_client).not_to have_received(:create_event)
    end

    it "refuses an event in another series" do
      elsewhere = create(:event, slug: "not-in-this-series")
      allow(vote_client).to receive(:find_event)
      sign_in owner

      post create_vote_event_admin_series_integrations_path(series, event_id: elsewhere.slug)

      expect(flash[:alert]).to eq("That event is not in this series.")
      expect(elsewhere.reload.vote_event_id).to be_nil
    end

    it "keeps a series organizer out" do
      allow(vote_client).to receive(:find_event)
      sign_in organizer

      post create_vote_event_admin_series_integrations_path(series, event_id: sub_event.slug)

      expect(response).to redirect_to(admin_series_path(series))
      expect(sub_event.reload.vote_event_id).to be_nil
    end
  end
end
