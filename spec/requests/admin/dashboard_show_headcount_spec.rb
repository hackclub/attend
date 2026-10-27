require "rails_helper"

RSpec.describe "Admin::Dashboard#show headcount", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-headcount@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event, travel_enabled: true) }

  # The legacy and console templates lay the tiles out differently, so find the
  # smallest element whose text is the label, climb to the tile around it and
  # read the first number in that tile. Travel's "Missing" appears twice, in
  # arrivals-then-departures order in both UIs.
  def tile_values(doc, label)
    matches = doc.css("p, dt, span, h3").select { |el| el.text.strip.casecmp?(label) }
    matches.filter_map do |el|
      tile = el.ancestors("div").first
      tile&.text&.[](/\d+/)&.to_i
    end
  end

  def tile_value(doc, label)
    values = tile_values(doc, label)
    expect(values).not_to be_empty, "no #{label} tile in the page"
    values.first
  end

  def each_admin_ui
    [ false, true ].each do |console|
      admin.update!(admin_console_beta: console)
      sign_in admin
      get admin_event_dashboard_path(event.slug)
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      yield doc, (console ? "console" : "legacy")
    end
  end

  it "leaves withdrawn and rejected registrations out of the total and the travel maths" do
    create(:participant_event, event: event, status: :complete)
    create(:participant_event, event: event, status: :in_progress)
    withdrawn = create(:participant_event, event: event, status: :withdrawn)
    create(:participant_event, event: event, status: :rejected)
    Travel.create!(participant_event: withdrawn, mode: "train", direction: "inbound", arrival_time: 1.day.from_now)

    each_admin_ui do |doc, ui|
      expect(tile_value(doc, "Total participants")).to eq(2), "#{ui}: total"
      expect(tile_values(doc, "Missing")).to eq([ 2, 2 ]), "#{ui}: travel missing counts"
    end
  end

  it "still shows withdrawn people in the status breakdown" do
    create(:participant_event, event: event, status: :withdrawn)

    each_admin_ui do |doc, ui|
      expect(tile_value(doc, "Total participants")).to eq(0), "#{ui}: total"
      expect(tile_value(doc, "Withdrawn")).to eq(1), "#{ui}: withdrawn tile"
    end
  end
end
