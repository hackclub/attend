require "rails_helper"

RSpec.describe "Admin::Dashboard#index", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:global_admin) { User.create!(email: "ga-events@example.com", name: "Global Admin", global_role: "global_admin", admin_console_beta: false) }

  before { sign_in global_admin }

  def row_order(body)
    body.scan(/href="\/admin\/([a-z0-9-]+)"/).flatten
  end

  describe "ordering" do
    let!(:far_future) { create(:event, name: "Far Future", slug: "far-future", starts_at: 6.months.from_now, ends_at: 6.months.from_now + 2.days) }
    let!(:tomorrow) { create(:event, name: "Tomorrow", slug: "tomorrow", starts_at: 1.day.from_now, ends_at: 3.days.from_now) }
    let!(:undated) { create(:event, name: "Undated", slug: "undated", starts_at: nil, ends_at: nil) }
    let!(:last_year) { create(:event, name: "Last Year", slug: "last-year", starts_at: 1.year.ago, ends_at: 1.year.ago + 2.days) }
    let!(:last_month) { create(:event, name: "Last Month", slug: "last-month", starts_at: 1.month.ago, ends_at: 1.month.ago + 2.days) }

    it "puts the soonest live or upcoming event first and undated drafts last" do
      get admin_root_path

      order = row_order(response.body)
      expect(order.index("tomorrow")).to be < order.index("far-future")
      expect(order.index("far-future")).to be < order.index("undated")
    end

    it "lists finished events most-recent-first" do
      get admin_root_path

      order = row_order(response.body)
      expect(order.index("last-month")).to be < order.index("last-year")
    end
  end

  describe "phase badges" do
    it "labels an event with no dates a draft rather than active" do
      create(:event, name: "Undated", slug: "undated", starts_at: nil, ends_at: nil)

      get admin_root_path

      expect(response.body).to include(">Draft<")
    end

    it "does not nag about setup on an event that has already finished" do
      create(:event, :draft, name: "Wrapped", slug: "wrapped", starts_at: 1.month.ago, ends_at: 3.weeks.ago)

      get admin_root_path

      expect(response.body).not_to include("Setup incomplete")
    end
  end

  describe "series groups" do
    let(:series) { create(:event_series, name: "Example Series") }
    let!(:first_event) { create(:event, name: "Series Stop One", slug: "series-stop-one", event_series: series, starts_at: 1.week.from_now, ends_at: 1.week.from_now + 2.days) }
    let!(:second_event) { create(:event, name: "Series Stop Two", slug: "series-stop-two", event_series: series, starts_at: 2.weeks.from_now, ends_at: 2.weeks.from_now + 2.days) }

    it "renders the series as a collapsed group holding both events" do
      get admin_root_path

      group = Nokogiri::HTML(response.body).at_css("details.group\\/series")
      expect(group).to be_present
      expect(group.key?("open")).to be(false)
      expect(group.at_css("summary").text).to include("Example Series")
      expect(group.css("a").map { |link| link["href"] }).to include("/admin/series-stop-one", "/admin/series-stop-two")
    end

    context "with the admin console beta" do
      before { global_admin.update!(admin_console_beta: true) }

      it "renders the series as a collapsed row group with a toggle" do
        get admin_root_path

        html = Nokogiri::HTML(response.body)
        toggle = html.at_css('button[data-action="cs-row-group#toggle"]')
        expect(toggle["aria-expanded"]).to eq("false")
        rows = html.css('tr[data-cs-row-group-target="row"]')
        expect(rows.size).to eq(2)
        expect(rows).to all(satisfy { |row| row.key?("hidden") })
        expect(toggle["aria-controls"].split).to match_array(rows.map { |row| row["id"] })
      end
    end
  end

  describe "when every visible event has finished" do
    let!(:finished) { create(:event, slug: "finished", starts_at: 1.month.ago, ends_at: 3.weeks.ago) }

    it "explains the gap instead of rendering a bare heading" do
      get admin_root_path

      expect(response.body).to include("Nothing running right now")
      expect(response.body).to include('<details class="mt-6 group/completed" open>')
    end

    context "with the admin console beta" do
      before { global_admin.update!(admin_console_beta: true) }

      it "explains the gap and opens the completed section" do
        get admin_root_path

        expect(response.body).to include("Nothing running right now")
        expect(response.body).to include('<details class="cs-expandable cs-expandable-container" open>')
      end
    end
  end

  describe "when there are no events at all" do
    it "renders the first-run empty state" do
      get admin_root_path

      expect(response.body).to include("No events yet")
    end
  end
end
