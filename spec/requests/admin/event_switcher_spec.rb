require "rails_helper"

# The console's event switcher sits in both the top nav and the mobile drawer.
RSpec.describe "Admin console event switcher", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin", admin_console_beta: true) }
  let!(:upcoming) { create(:event, name: "Upcoming Hacks", starts_at: 2.weeks.from_now, ends_at: 2.weeks.from_now + 2.days) }
  let!(:long_past) { create(:event, name: "Bygone Hacks", starts_at: 2.months.ago, ends_at: 2.months.ago + 2.days) }

  before { sign_in admin }

  def switcher_lists
    Nokogiri::HTML(response.body).css(".cs-menu-scroll")
  end

  it "lists running and upcoming events in both menus, and leaves finished ones out" do
    get admin_series_index_path

    expect(switcher_lists.size).to eq(2)
    switcher_lists.each do |list|
      expect(list.text).to include("Upcoming Hacks")
      expect(list.text).not_to include("Bygone Hacks")
    end
  end

  it "still leads with the current event when it has finished" do
    get select_admin_event_path(slug: long_past.slug)
    get admin_series_index_path

    switcher_lists.each do |list|
      expect(list.at_css(".cs-menu-item[aria-current='true']").text).to include("Bygone Hacks")
    end
  end

  it "closes the mobile drawer when an event is picked from it" do
    get admin_series_index_path

    drawer_list = switcher_lists.find { |list| list.parent["data-action"] == "click->mobile-menu#close" }
    expect(drawer_list).to be_present
  end
end
