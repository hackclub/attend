require "rails_helper"

# Both admin UIs carry an event switcher in the desktop nav and again in the
# mobile drawer.
RSpec.describe "Admin event switcher", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }
  let!(:upcoming) { create(:event, name: "Upcoming Hacks", starts_at: 2.weeks.from_now, ends_at: 2.weeks.from_now + 2.days) }
  let!(:long_past) { create(:event, name: "Bygone Hacks", starts_at: 2.months.ago, ends_at: 2.months.ago + 2.days) }

  before { sign_in admin }

  context "in the original admin" do
    before { admin.update!(admin_console_beta: false) }

    def switcher_lists
      Nokogiri::HTML(response.body).css(".sidebar-dropdown .max-h-72")
    end

    it "lists running and upcoming events in both menus, and leaves finished ones out" do
      get admin_series_index_path

      lists = switcher_lists
      expect(lists.size).to eq(2)
      lists.each do |list|
        expect(list.text).to include("Upcoming Hacks")
        expect(list.text).not_to include("Bygone Hacks")
      end
    end

    it "still shows the current event when it has finished" do
      get select_admin_event_path(slug: long_past.slug)
      get admin_series_index_path

      lists = switcher_lists
      expect(lists.size).to eq(2)
      lists.each do |list|
        expect(list.at_css(".sidebar-dropdown-item-active").text).to include("Bygone Hacks")
      end
    end
  end

  # The console's menus load their list the first time they open, from
  # admin_event_switcher_path, instead of rendering it into every page.
  context "with the admin console beta" do
    before { admin.update!(admin_console_beta: true) }

    def switcher_list(frame_id)
      get admin_event_switcher_path, headers: { "Turbo-Frame" => frame_id }
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body).at_css("turbo-frame##{frame_id} .cs-menu-scroll")
    end

    it "puts a lazy frame in each menu instead of the list" do
      get admin_series_index_path

      frames = Nokogiri::HTML(response.body).css("turbo-frame[id^='event_switcher_items_']")
      expect(frames.map { |frame| frame["id"] }).to contain_exactly("event_switcher_items_topnav", "event_switcher_items_drawer")
      frames.each do |frame|
        expect(frame["src"]).to eq(admin_event_switcher_path)
        expect(frame["loading"]).to eq("lazy")
      end
      expect(response.body).not_to include("Upcoming Hacks")
    end

    it "lists running and upcoming events in both menus, and leaves finished ones out" do
      %w[event_switcher_items_topnav event_switcher_items_drawer].each do |frame_id|
        list = switcher_list(frame_id)
        expect(list.text).to include("Upcoming Hacks")
        expect(list.text).not_to include("Bygone Hacks")
      end
    end

    it "still shows the current event when it has finished" do
      get select_admin_event_path(slug: long_past.slug)

      list = switcher_list("event_switcher_items_topnav")
      expect(list.at_css(".cs-menu-item[aria-current='true']").text).to include("Bygone Hacks")
    end

    it "closes the mobile drawer when an event is picked from it" do
      get admin_series_index_path

      drawer_frame = Nokogiri::HTML(response.body).at_css("turbo-frame#event_switcher_items_drawer")
      expect(drawer_frame.parent["data-action"]).to eq("click->mobile-menu#close")
    end
  end
end
