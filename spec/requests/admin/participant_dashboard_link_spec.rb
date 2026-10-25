require "rails_helper"

# Staff who are also registered for an upcoming event get a link from either
# admin UI across to their own participant dashboard.
RSpec.describe "Admin link to the participant dashboard", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:staff) do
    User.create!(email: "staff-dashboard-link@example.com", name: "Placeholder Staffer", global_role: "global_admin")
  end
  let(:upcoming_event) { create(:event, name: "Placeholder Future Jam") }
  let(:past_event) { create(:event, name: "Placeholder Past Jam", starts_at: 3.weeks.ago, ends_at: 2.weeks.ago) }

  def dashboard_links
    Nokogiri::HTML(response.body).css("a[href='#{dashboard_path}']")
  end

  def register(event, status: :in_progress)
    participant = create(:participant, email: staff.email, user: staff)
    create(:participant_event, participant: participant, event: event, status: status)
  end

  [ true, false ].each do |console|
    context "in the #{console ? "console" : "original admin"}" do
      before do
        staff.update!(admin_console_beta: console)
        sign_in staff
      end

      it "links to /dashboard when the user is registered for an upcoming event" do
        register(upcoming_event)

        get admin_root_path

        expect(dashboard_links).not_to be_empty
      end

      it "leaves the link out when the user has no participant record" do
        get admin_root_path

        expect(dashboard_links).to be_empty
      end

      it "leaves the link out when every registration is for an event that has ended" do
        register(past_event)

        get admin_root_path

        expect(dashboard_links).to be_empty
      end

      it "leaves the link out when the upcoming registration was withdrawn" do
        register(upcoming_event, status: :withdrawn)

        get admin_root_path

        expect(dashboard_links).to be_empty
      end
    end
  end
end
