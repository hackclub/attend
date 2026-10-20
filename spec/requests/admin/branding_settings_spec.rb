require "rails_helper"

# Registration branding, notes and account linking are editable from both
# the classic admin and the console (admin v2), with the same fields.
RSpec.describe "Admin branding and account linking settings", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:series) { create(:event_series, name: "Sunbeam", slug: "sunbeam-branding") }
  let!(:event) { create(:event, event_series: series) }
  let(:standalone_event) { create(:event) }

  let(:brand_params) do
    {
      background: "#fff6d6", ink: "#4a2a12", accent: "#ed5615", accent_fill: "#b8430f",
      secondary: "#b8c220", highlight: "#fba71f", card_from: "#ffe382", card_to: "#fee0b1",
      body_font: "jua", heading_font: "darumadrop-one", nav_style: "progress",
      logo_image: "brands/haven/haven-logo-color.webp", mascot_image: "brands/haven/hedgehog.webp",
      footer_image: "brands/haven/bottom-bushes.webp", tshirt_image: "",
      tokens: "text-muted: #8a6440"
    }
  end
  let(:series_params) do
    {
      brand: brand_params,
      registration_note: "Bring a laptop!", address_note: "For posting prizes.", tshirt_note: "Unisex sizing.",
      github_linking: "required", itch_linking: "optional",
      github_help_url: "https://example.com/github-howto", itch_help_url: ""
    }
  end

  { "classic admin" => false, "admin console" => true }.each do |label, console|
    context "in the #{label}" do
      let(:admin) do
        User.create!(email: "branding-#{console}@example.com", name: "Robin Placeholder",
          global_role: "global_admin", admin_console_beta: console)
      end

      before { sign_in admin }

      def form_names
        Nokogiri::HTML(response.body).css("main form input, main form select, main form textarea").filter_map { |field| field["name"] }
      end

      it "shows every branding, note and linking field on the series form" do
        get edit_admin_series_path(series)

        expect(response).to have_http_status(:ok)
        names = form_names
        BrandTheme::FIELDS.each { |field| expect(names).to include("event_series[brand][#{field}]") }
        %w[registration_note address_note tshirt_note github_linking itch_linking github_help_url itch_help_url].each do |field|
          expect(names).to include("event_series[#{field}]")
        end
        expect(names).not_to include("event_series[haven_onboarding]")
      end

      it "saves the full set of branding settings" do
        patch admin_series_path(series), params: { event_series: series_params }

        series.reload
        expect(series.brand_theme.settings).to eq(
          brand_params.except(:tshirt_image, :tokens).transform_keys(&:to_s).merge("tokens" => { "text-muted" => "#8a6440" })
        )
        expect(series.registration_note).to eq("Bring a laptop!")
        expect(series.address_note).to eq("For posting prizes.")
        expect(series.tshirt_note).to eq("Unisex sizing.")
        expect(event.reload.account_linking_mode("github")).to eq("required")
        expect(event.account_help_url("github")).to eq("https://example.com/github-howto")
      end

      it "explains contrast failures on the form instead of saving" do
        patch admin_series_path(series), params: { event_series: { brand: brand_params.merge(ink: "#eeeeee") } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("below the 4.5:1 minimum")
        expect(series.reload.brand).to be_blank
      end

      it "shows account linking on the event form, inheriting from the series" do
        get edit_admin_event_path(event)

        expect(response).to have_http_status(:ok)
        names = form_names
        %w[github_linking itch_linking github_help_url itch_help_url].each { |field| expect(names).to include("event[#{field}]") }
        expect(response.body).to include("Same as series (Don&#39;t ask)")
        expect(response.body).to include("OAuth credentials aren&#39;t configured") unless AccountLinking.available?("github")
      end

      it "lets an event outside any series ask for accounts" do
        patch admin_event_path(standalone_event), params: { event: { github_linking: "optional", itch_help_url: "https://example.com/itch-howto" } }

        standalone_event.reload
        expect(standalone_event.linked_account_providers).to eq(%w[github])
        expect(standalone_event.account_help_url("itch")).to eq("https://example.com/itch-howto")
      end
    end
  end
end
