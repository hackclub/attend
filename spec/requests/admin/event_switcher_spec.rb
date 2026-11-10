require "rails_helper"

# Both admin UIs carry an event switcher in the desktop nav and again in the
# mobile drawer.
RSpec.describe "Admin event switcher", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }
  let!(:upcoming) { create(:event, name: "Upcoming Hacks", starts_at: 2.weeks.from_now, ends_at: 2.weeks.from_now + 2.days) }
  let!(:long_past) { create(:event, name: "Bygone Hacks", starts_at: 2.months.ago, ends_at: 2.months.ago + 2.days) }

  before { sign_in admin }

  {
    "in the original admin" => [ false, ".sidebar-dropdown .max-h-72", ".sidebar-dropdown-item-active" ],
    "with the admin console beta" => [ true, ".cs-menu-scroll", ".cs-menu-item[aria-current='true']" ]
  }.each do |ui, (console, list_selector, current_selector)|
    context ui do
      before { admin.update!(admin_console_beta: console) }

      def switcher_lists(selector)
        Nokogiri::HTML(response.body).css(selector)
      end

      it "lists running and upcoming events in both menus, and leaves finished ones out" do
        get admin_series_index_path

        lists = switcher_lists(list_selector)
        expect(lists.size).to eq(2)
        lists.each do |list|
          expect(list.text).to include("Upcoming Hacks")
          expect(list.text).not_to include("Bygone Hacks")
        end
      end

      it "still shows the current event when it has finished" do
        get select_admin_event_path(slug: long_past.slug)
        get admin_series_index_path

        lists = switcher_lists(list_selector)
        expect(lists.size).to eq(2)
        lists.each do |list|
          expect(list.at_css(current_selector).text).to include("Bygone Hacks")
        end
      end
    end
  end

  it "closes the console's mobile drawer when an event is picked from it" do
    admin.update!(admin_console_beta: true)
    get admin_series_index_path

    drawer_list = switcher_lists_in_console.find { |list| list.parent["data-action"] == "click->mobile-menu#close" }
    expect(drawer_list).to be_present
  end

  def switcher_lists_in_console
    Nokogiri::HTML(response.body).css(".cs-menu-scroll")
  end
end
