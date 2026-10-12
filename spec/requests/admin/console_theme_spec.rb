require "rails_helper"

# The admin console has Cloudscape's two modes plus "system". Any app theme
# collapses to light or dark; "system" renders light and is resolved to the
# OS setting in the browser before first paint.
RSpec.describe "Admin console theme", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) do
    User.create!(email: "console-theme-spec@example.com", name: "Theme Tester",
      global_role: "global_admin", admin_console_beta: true)
  end

  def html_attrs
    Nokogiri::HTML(response.body).at("html")
  end

  before { sign_in user }

  it "offers Light, Dark and System with the saved one pressed" do
    user.update!(theme: "dark")
    get admin_root_path

    options = Nokogiri::HTML(response.body).css('[data-console-theme-target="option"]')
    expect(options.map { |o| o.text.strip }).to eq(%w[Light Dark System])
    expect(options.find { |o| o["aria-pressed"] == "true" }.text.strip).to eq("Dark")
  end

  it "collapses an app theme to light or dark" do
    user.update!(theme: "dracula")
    get admin_root_path
    expect(html_attrs["data-theme"]).to eq("dark")
    expect(html_attrs["data-theme-mode"]).to eq("dark")

    user.update!(theme: "catppuccin-latte")
    get admin_root_path
    expect(html_attrs["data-theme"]).to eq("light")
    expect(html_attrs["data-theme-mode"]).to eq("light")
  end

  it "renders system as light and leaves the OS check to the pre-paint script" do
    user.update!(theme: "system")
    get admin_root_path

    expect(html_attrs["data-theme"]).to eq("light")
    expect(html_attrs["data-theme-mode"]).to eq("system")
    expect(response.body).to include('matchMedia("(prefers-color-scheme: dark)")')
  end

  it "saves system through the theme endpoint" do
    post update_theme_path, params: { theme: "system" }, as: :json

    expect(response.parsed_body["theme"]).to eq("system")
    expect(user.reload.theme).to eq("system")
  end

  it "still rejects unknown themes" do
    post update_theme_path, params: { theme: "neon" }, as: :json
    expect(user.reload.theme).to eq("light")
  end

  it "shows a saved system theme as light outside the console" do
    user.update!(theme: "system", admin_console_beta: false)
    get admin_root_path

    expect(html_attrs["class"].to_s).not_to include("cs-console")
    expect(html_attrs["data-theme"]).to eq("light")
  end
end
