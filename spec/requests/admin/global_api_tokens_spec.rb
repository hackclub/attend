require "rails_helper"

RSpec.describe "Admin::GlobalApiTokens", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: :global_admin) }

  before { sign_in admin }

  it "offers each available scope on the create form" do
    get admin_global_api_tokens_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("bans:write")
    expect(response.body).to include("Add emails to the ban list")
  end

  it "issues a token limited to the ticked scopes" do
    post admin_global_api_tokens_path, params: { name: "ban bot", scopes: [ "bans:write" ] }

    token = GlobalApiToken.last
    expect(token.scopes).to eq([ "bans:write" ])
    expect(token.name).to eq("ban bot")
  end

  it "issues a full-access token when no scope is ticked" do
    post admin_global_api_tokens_path, params: { name: "reporting" }

    expect(GlobalApiToken.last).to be_unrestricted
  end

  # A hand-crafted form post shouldn't be able to invent a scope that no
  # controller honours — that would read as "restricted" while permitting
  # nothing, which is confusing rather than dangerous, but still wrong.
  it "drops a scope the app doesn't define" do
    post admin_global_api_tokens_path, params: { scopes: [ "bans:write", "everything" ] }

    expect(GlobalApiToken.last.scopes).to eq([ "bans:write" ])
  end

  it "shows how each token is scoped in the list" do
    GlobalApiToken.generate_for(admin, name: "ban bot", scopes: [ "bans:write" ])
    GlobalApiToken.generate_for(admin, name: "reporting")

    get admin_global_api_tokens_path

    expect(response.body).to include("Add emails to the ban list")
    expect(response.body).to include("Full access")
  end

  # Bounced by Admin::BaseController before the tokens controller is reached,
  # so assert on the outcome rather than on which path it lands at.
  it "keeps non-admins out" do
    sign_in create(:user)
    post admin_global_api_tokens_path, params: { scopes: [ "bans:write" ] }

    expect(response).to have_http_status(:redirect)
    expect(GlobalApiToken.count).to eq(0)
  end
end
