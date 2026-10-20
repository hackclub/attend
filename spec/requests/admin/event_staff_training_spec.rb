require "rails_helper"

RSpec.describe "Event staff training flags", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }
  let(:event) { create(:event) }
  let!(:badge) { create(:training_badge, name: "Example Event Badge", required_roles: %w[ops volunteer]) }

  before do
    sign_in admin
    get select_admin_event_path(slug: event.slug)
  end

  [ true, false ].each do |console|
    it "flags who has and hasn't trained (#{console ? "console" : "original"})" do
      admin.update!(admin_console_beta: console)
      trained = create(:event_role_assignment, event: event, role: "ops").user
      create(:training_badge_award, user: trained, badge: badge)
      create(:event_role_assignment, event: event, role: "ops")
      create(:event_volunteer, event: event)

      get admin_event_staff_index_path(event_slug: event.slug)

      expect(response.body).to include("Trained")
      expect(response.body.scan("Not trained").size).to be >= 2
      expect(response.body).to include("2 of 3 people need to complete their training")
      expect(response.body).to include("Volunteers")
    end
  end

  it "adds a volunteer by email, emails them, and grants no admin access" do
    expect {
      post admin_event_volunteers_path(event_slug: event.slug), params: { email: "new-volunteer@example.com" }
    }.to have_enqueued_mail(TrainingMailer, :volunteer_added)

    volunteer = User.find_by!(email: "new-volunteer@example.com")
    expect(event.event_volunteers.pluck(:user_id)).to eq([ volunteer.id ])
    expect(volunteer.admin?).to be(false)
    expect(volunteer.can_access_event?(event)).to be(false)
  end

  it "removes a volunteer" do
    record = create(:event_volunteer, event: event)
    expect {
      delete admin_event_volunteer_path(event_slug: event.slug, id: record.id)
    }.to change(EventVolunteer, :count).by(-1)
  end

  it "reminds a staff member who hasn't trained, on every page of the event" do
    staff = create(:event_role_assignment, event: event, role: "ops").user
    sign_in staff
    get select_admin_event_path(slug: event.slug)
    get admin_event_dashboard_path(event.slug)
    expect(response.body).to include('data-testid="training-banner"')
  end
end
