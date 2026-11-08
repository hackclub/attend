require "rails_helper"

# Event staff spend their time in /admin, which has no top nav, so the side nav
# links back to their own training (not /admin/training, which manages it).
RSpec.describe "My training link in the admin side nav", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, starts_at: 3.weeks.ago, ends_at: 20.days.ago) }
  let(:staff) { create(:user) }

  before do
    create(:event_role_assignment, event: event, user: staff, role: "event_admin")
    sign_in staff
  end

  def training_links
    Nokogiri::HTML(response.body).css("a[href='#{training_path}']").select { |link| link.text.include?("My training") }
  end

  { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
    context ui do
      before { staff.update!(admin_console_beta: console) }

      it "links to the person's training once a course is published" do
        create(:training_course, :published)
        get admin_root_path

        expect(response).to have_http_status(:ok)
        expect(training_links).not_to be_empty
      end

      it "leaves it out while there's no published course to take" do
        create(:training_course)
        get admin_root_path

        expect(response).to have_http_status(:ok)
        expect(training_links).to be_empty
      end
    end
  end
end
