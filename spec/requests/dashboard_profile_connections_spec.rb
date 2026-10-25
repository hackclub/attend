require "rails_helper"

RSpec.describe "Profile connections: GitHub and itch.io", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user) }
  let!(:participant) { create(:participant, user: user, email: user.email) }
  let(:connections_path) { "/dashboard/profile#connections" }

  before { sign_in user }

  def section
    Nokogiri::HTML(response.body).at_css("#connections")
  end

  context "with OAuth credentials set up" do
    before { stub_account_linking_credentials }

    it "offers to connect each account, coming back to the section" do
      get dashboard_profile_path

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).at_css('a[href="#connections"]')).to be_present
      %w[github itch].each do |provider|
        form = section.at_css("form[action^='#{connect_account_path(provider: provider)}']")
        expect(form).to be_present, "no connect form for #{provider}"
        expect(Rack::Utils.parse_query(URI.parse(form["action"]).query)["return_to"]).to eq(connections_path)
      end
      expect(section.text).to include("Connect GitHub", "Connect itch.io")
    end

    it "shows a linked account with a way to disconnect it" do
      participant.connected_accounts.create!(provider: "github", uid: "1", username: "octo-sample",
        access_token: "gho_sample", connected_at: Time.zone.local(2026, 10, 1))

      get dashboard_profile_path

      row = section.at_css("#connection-github")
      expect(row.text).to include("Connected as octo-sample", "Oct 1, 2026")
      expect(row.at_css("a[href='https://github.com/octo-sample']")).to be_present
      expect(row.at_css("form[action^='#{disconnect_account_path(provider: "github")}'] input[name='_method'][value='delete']")).to be_present
      expect(section.at_css("#connection-itch").text).to include("Not connected")
    end

    it "sends a connect from the profile back to the profile" do
      post connect_account_path(provider: "github"), params: { return_to: connections_path }

      expect(response.location).to start_with("https://github.com/login/oauth/authorize")
      expect(session[:account_link]["return_to"]).to eq(connections_path)
    end

    it "disconnects back to the profile" do
      participant.connected_accounts.create!(provider: "itch", uid: "2", username: "sample-maker",
        access_token: "itch_sample", connected_at: Time.current)
      stub_request(:any, /itch\.io/).to_return(status: 200, body: "{}")

      delete disconnect_account_path(provider: "itch"), params: { return_to: connections_path }

      expect(response).to redirect_to(connections_path)
      expect(ConnectedAccount.where(participant: participant)).to be_empty
    end
  end

  it "says when a provider can't be linked yet instead of offering a dead button" do
    stub_account_linking_credentials(github: false, itch: false)

    get dashboard_profile_path

    expect(section.text).to include("GitHub linking isn't available right now.", "itch.io linking isn't available right now.")
    expect(section.css("form[action^='/connected_accounts']")).to be_empty
  end

  context "for staff without a participant record" do
    let(:user) { create(:user, global_role: "global_admin") }
    let!(:participant) { nil }

    it "shows their MCP connections but nothing to link" do
      get dashboard_profile_path

      expect(response).to have_http_status(:ok)
      expect(section.text).to include("Apps connected through MCP")
      expect(section.at_css("#connection-github")).to be_nil
    end
  end
end
