require "rails_helper"

# Event settings used to be split between a Settings page and an Integrations
# page that each held some of the waiver and account settings. The console
# now has one Settings area with tabs, and every box on a tab saves on its own.
RSpec.describe "Admin event settings tabs", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:admin) { User.create!(email: "settings-tabs-admin@example.com", name: "Admin", global_role: "global_admin", admin_console_beta: true) }

  def staff_with(role, console: true)
    User.create!(email: "settings-tabs-#{role}@example.com", name: role.titleize, admin_console_beta: console).tap do |user|
      EventRoleAssignment.create!(user: user, event: event, role: role)
    end
  end

  def page
    Nokogiri::HTML5(response.body)
  end

  def tab_labels
    page.css("nav.cs-tabs a.cs-tab").map { |a| a.text.strip }
  end

  def field_names
    page.css("input[name], select[name], textarea[name]").map { |el| el["name"] }
  end

  ALL_TABS = [ "General", "Features", "Waivers & documents", "Integrations", "API access" ].freeze

  describe "in the console" do
    before { sign_in admin }

    it "shows the same five tabs on every settings page, marking the current one" do
      {
        edit_admin_event_path(event) => "General",
        features_admin_event_path(event) => "Features",
        admin_event_documents_path(event) => "Waivers & documents",
        admin_event_integrations_path(event) => "Integrations",
        admin_event_api_access_path(event) => "API access"
      }.each do |path, current|
        get path

        expect(response).to have_http_status(:ok), path
        expect(tab_labels).to eq(ALL_TABS), path
        expect(page.at_css("nav.cs-tabs a[aria-current='page']").text.strip).to eq(current), path
      end
    end

    it "puts each setting on exactly one tab" do
      get edit_admin_event_path(event)
      expect(field_names).to include("event[name]", "event[starts_at]")
      expect(field_names).not_to include("event[freedom_waivers_enabled]", "event[github_linking]", "event[nfc_badges_enabled]")

      get features_admin_event_path(event)
      expect(field_names).to include("event[travel_enabled]", "event[nfc_badges_enabled]", "event[groups_enabled]")
      expect(field_names).not_to include("event[freedom_waivers_enabled]", "event[guardian_invites_locked]", "event[name]")

      get admin_event_documents_path(event)
      expect(field_names).to include("event[freedom_waivers_enabled]", "event[guardian_invites_locked]", "event[docuseal_waiver_template_id]", "custom_document[name]")
      expect(field_names).not_to include("event[slack_channel_id]")

      get admin_event_integrations_path(event)
      expect(field_names).to include("event[slack_channel_id]", "event[github_linking]")
      expect(field_names).not_to include("event[docuseal_waiver_template_id]", "custom_document[name]", "name")

      get admin_event_api_access_path(event)
      expect(response.body).to include("No API tokens yet")
      expect(field_names).not_to include("event[slack_channel_id]")
    end

    it "gives every box its own Save button and no page-wide one" do
      [ edit_admin_event_path(event), features_admin_event_path(event), admin_event_documents_path(event), admin_event_integrations_path(event) ].each do |path|
        get path

        settings_forms = page.css("form").select { |form| form.at_css("section.cs-container") }
        expect(settings_forms).not_to be_empty, path
        settings_forms.each do |form|
          expect(form.css("section.cs-container").size).to eq(1), "#{path}: a form wraps more than one box"
          expect(form.at_css("section.cs-container .cs-container-footer button")&.text&.strip).to eq("Save"), path
        end
        expect(response.body).not_to include("Save integration settings")
      end
    end

    it "saves one box at a time and goes back to the tab it came from" do
      patch admin_event_path(event), params: { tab: "features", event: { nfc_badges_enabled: "1" } }
      expect(response).to redirect_to(features_admin_event_path(event))
      expect(event.reload.nfc_badges_enabled?).to be(true)

      patch admin_event_path(event), params: { tab: "general", event: { venue_name: "Fictional Hall" } }
      expect(response).to redirect_to(edit_admin_event_path(event))
      expect(event.reload.venue_name).to eq("Fictional Hall")

      patch admin_event_integrations_path(event), params: { tab: "documents", event: { freedom_waivers_enabled: "1", guardian_invites_locked: "1" } }
      expect(response).to redirect_to(admin_event_documents_path(event))
      expect(event.reload).to have_attributes(freedom_waivers_enabled?: true, guardian_invites_locked?: true)

      patch admin_event_integrations_path(event), params: { event: { github_linking: "optional" } }
      expect(response).to redirect_to(admin_event_integrations_path(event))
      expect(event.reload.linked_account_providers).to eq(%w[github])

      # A box saves only its own fields; the others are left as they were.
      expect(event.reload).to have_attributes(venue_name: "Fictional Hall", nfc_badges_enabled?: true)
    end

    it "re-renders the box's own tab when a save is invalid" do
      patch admin_event_path(event), params: { tab: "general", event: { name: "" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(page.at_css("nav.cs-tabs a[aria-current='page']").text.strip).to eq("General")
    end

    it "has one Settings entry on the overview and in the side navigation" do
      get admin_event_dashboard_path(event.slug)

      header_links = page.css(".cs-header .cs-actions a").map { |a| a.text.strip }
      expect(header_links).to include("Settings")
      expect(header_links).not_to include("Integrations")
      expect(page.css("a.cs-sidenav-link").map { |a| a.text.strip }).to include("Settings")

      get admin_event_api_access_path(event)
      expect(page.at_css("a.cs-sidenav-link[aria-current='page']").text.strip).to eq("Settings")
    end
  end

  describe "who sees which tabs" do
    it "shows staff without integrations access only General and Features" do
      sign_in staff_with("limited")

      get edit_admin_event_path(event)
      expect(tab_labels).to eq([ "General", "Features" ])

      get admin_event_documents_path(event)
      expect(response).to have_http_status(:redirect)
      expect(response).not_to redirect_to(admin_event_documents_path(event))
    end

    it "shows ops every tab" do
      sign_in staff_with("ops")

      get admin_event_api_access_path(event)

      expect(response).to have_http_status(:ok)
      expect(tab_labels).to eq(ALL_TABS)
    end
  end

  describe "in the original admin" do
    before do
      admin.update!(admin_console_beta: false)
      sign_in admin
    end

    it "sends the console-only tabs to the page that still holds their settings" do
      get features_admin_event_path(event)
      expect(response).to redirect_to(edit_admin_event_path(event))

      get admin_event_documents_path(event)
      expect(response).to redirect_to(admin_event_integrations_path(event))

      get admin_event_api_access_path(event)
      expect(response).to redirect_to(admin_event_integrations_path(event))
    end

    it "keeps a one-time token visible through the extra redirect" do
      post admin_event_api_tokens_path(event.slug), params: { name: "fictional-widget-sync" }
      expect(response).to redirect_to(admin_event_api_access_path(event))

      follow_redirect!
      expect(response).to redirect_to(admin_event_integrations_path(event))

      follow_redirect!
      expect(response.body).to include("Copy this token now")
    end

    it "still goes back to the overview after saving its single form" do
      patch admin_event_path(event), params: { event: { venue_name: "Fictional Hall" } }

      expect(response).to redirect_to(admin_event_dashboard_path(event))
    end
  end

  describe "series settings" do
    let(:series) { create(:event_series, name: "Fictional Series", slug: "fictional-settings-series") }
    let(:owner) do
      User.create!(email: "settings-tabs-owner@example.com", name: "Owner", admin_console_beta: true).tap do |user|
        SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
      end
    end

    before { sign_in owner }

    it "puts General, Members, Integrations and API keys under one Settings tab bar" do
      [ edit_admin_series_path(series), admin_series_members_path(series), admin_series_integrations_path(series), admin_series_api_tokens_path(series) ].each do |path|
        get path

        expect(response).to have_http_status(:ok), path
        expect(tab_labels).to eq([ "General", "Members", "Integrations", "API keys" ]), path
      end

      get admin_series_path(series)
      header_links = page.css(".cs-header .cs-actions a").map { |a| a.text.strip }
      expect(header_links).to include("Settings")
      expect(header_links).not_to include("Members", "API keys", "Integrations")
    end

    it "saves each General box on its own and stays on the tab" do
      get edit_admin_series_path(series)
      expect(page.css("form").count { |form| form.at_css("section.cs-container .cs-container-footer button") }).to eq(5)

      patch admin_series_path(series), params: { tab: "general", event_series: { description: "A fictional series" } }

      expect(response).to redirect_to(edit_admin_series_path(series))
      expect(series.reload.description).to eq("A fictional series")
    end
  end
end
