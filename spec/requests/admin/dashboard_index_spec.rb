require "rails_helper"

RSpec.describe "Admin::Dashboard#index", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:global_admin) { User.create!(email: "ga-events@example.com", name: "Global Admin", global_role: "global_admin") }

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

  describe "when every visible event has finished" do
    let!(:finished) { create(:event, slug: "finished", starts_at: 1.month.ago, ends_at: 3.weeks.ago) }

    it "explains the gap instead of rendering a bare heading" do
      get admin_root_path

      expect(response.body).to include("Nothing running right now")
      expect(response.body).to include('<details class="mt-6 group" open>')
    end
  end

  describe "when there are no events at all" do
    it "renders the first-run empty state" do
      get admin_root_path

      expect(response.body).to include("No events yet")
    end
  end
end
