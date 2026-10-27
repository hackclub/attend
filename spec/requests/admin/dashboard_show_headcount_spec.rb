require "rails_helper"

RSpec.describe "Admin::Dashboard#show headcount", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-headcount@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event, travel_enabled: true) }

  before { sign_in admin }

  def stat(body, label)
    value = body[/#{Regexp.escape(label)}<\/p>\s*<p[^>]*>(\d+)<\/p>/m, 1]
    expect(value).not_to be_nil, "no #{label} stat in the page"
    value.to_i
  end

  def travel_missing(body, heading)
    section = body.split(heading).last
    value = section[/Missing<\/span>\s*<span[^>]*>(\d+)<\/span>/m, 1]
    expect(value).not_to be_nil, "no Missing count under #{heading}"
    value.to_i
  end

  it "leaves withdrawn and rejected registrations out of the total and the travel maths" do
    create(:participant_event, event: event, status: :complete)
    create(:participant_event, event: event, status: :in_progress)
    withdrawn = create(:participant_event, event: event, status: :withdrawn)
    create(:participant_event, event: event, status: :rejected)
    Travel.create!(participant_event: withdrawn, mode: "train", direction: "inbound", arrival_time: 1.day.from_now)

    get admin_event_dashboard_path(event.slug)

    expect(response).to have_http_status(:ok)
    expect(stat(response.body, "Total Participants")).to eq(2)
    expect(travel_missing(response.body, "Arrivals (Inbound)")).to eq(2)
    expect(travel_missing(response.body, "Departures (Outbound)")).to eq(2)
  end

  it "still shows withdrawn people in the status breakdown" do
    create(:participant_event, event: event, status: :withdrawn)

    get admin_event_dashboard_path(event.slug)

    expect(stat(response.body, "Total Participants")).to eq(0)
    expect(response.body).to match(/<p class="text-2xl font-bold">1<\/p>\s*<p[^>]*>Withdrawn<\/p>/m)
  end
end
