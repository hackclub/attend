require "rails_helper"

RSpec.describe "Dashboard passport profile", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user) }

  before do
    create(:participant, user: user, email: user.email)
    sign_in user
  end

  it "does not show passport navigation or content without a paired passport" do
    get dashboard_profile_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Hack Club Passport", "#passport")
  end

  it "does not show a pending passport" do
    pending = create(:passport, user: user)

    get dashboard_profile_path

    expect(response.body).not_to include("Hack Club Passport", pending.serial_number, pending.token)
  end

  it "shows active and revoked paired passports without private or administrative data" do
    staff = create(:user, name: "Private Pairing Admin")
    active = create(:passport, :active, user: user, paired_by: staff, paired_at: Time.zone.local(2026, 8, 20, 12))
    revoked = create(:passport, :revoked, user: user, paired_at: Time.zone.local(2026, 7, 10, 12))

    get dashboard_profile_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      "Hack Club Passport",
      'href="#passport"',
      active.serial_number,
      revoked.serial_number,
      "Active",
      "Revoked",
      "August 20, 2026",
      "July 10, 2026"
    )
    expect(response.body).not_to include(
      active.token,
      revoked.token,
      staff.display_name_or_fallback,
      "Pair passport",
      ">Revoke<"
    )
  end
end
