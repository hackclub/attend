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

  it "lists the series team with their training, without a role on the event" do
    series = create(:event_series)
    event.update!(event_series: series)
    organizer = create(:user, name: "Example Organizer", email: "series-organizer@example.com")
    SeriesRoleAssignment.create!(user: organizer, event_series: series, role: "organizer")
    badge.update!(required_roles: %w[event_admin])

    get admin_event_staff_index_path(event_slug: event.slug)
    expect(response.body).to include("Series team", "series-organizer@example.com", "Not trained")
  end

  it "saves a badge required of everyone working an event" do
    patch admin_training_badge_path(badge), params: { training_badge: { required_roles: [ "", TrainingBadge::EVERYONE ] } }
    expect(badge.reload).to be_required_of_everyone

    get admin_training_badge_path(badge)
    expect(response.body).to include("Everyone working an event")
  end
  describe "as staff who aren't event admins" do
    let(:staff) { create(:event_role_assignment, event: event, role: "limited").user }
    let!(:colleague) { create(:event_role_assignment, event: event, role: "ops") }

    before do
      sign_in staff
      get select_admin_event_path(slug: event.slug)
    end

    [ true, false ].each do |console|
      it "shows the roster and the volunteer form, without staff controls (#{console ? "console" : "original"})" do
        staff.update!(admin_console_beta: console)

        get admin_event_staff_index_path(event_slug: event.slug)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(colleague.user.email, "Volunteers", admin_event_volunteers_path(event))
        expect(response.body).not_to include(new_admin_event_staff_path(event))
        expect(response.body).not_to include(admin_event_staff_path(event, colleague))
      end
    end

    it "adds and removes volunteers" do
      expect {
        post admin_event_volunteers_path(event_slug: event.slug), params: { email: "another-volunteer@example.com" }
      }.to have_enqueued_mail(TrainingMailer, :volunteer_added)
      record = event.event_volunteers.sole
      expect(record.added_by).to eq(staff)

      expect {
        delete admin_event_volunteer_path(event_slug: event.slug, id: record.id)
      }.to change(EventVolunteer, :count).by(-1)
    end

    it "still can't add, change or remove staff" do
      expect {
        post admin_event_staff_index_path(event_slug: event.slug),
          params: { email: "sneaky@example.com", event_role_assignment: { role: "event_admin" } }
      }.not_to change(EventRoleAssignment, :count)

      patch admin_event_staff_path(event_slug: event.slug, id: colleague.id), params: { event_role_assignment: { role: "event_admin" } }
      expect(colleague.reload.role).to eq("ops")

      expect {
        delete admin_event_staff_path(event_slug: event.slug, id: colleague.id)
      }.not_to change(EventRoleAssignment, :count)
    end
  end

  it "doesn't let someone with no role on the event add volunteers" do
    sign_in create(:user)
    expect {
      post admin_event_volunteers_path(event_slug: event.slug), params: { email: "another-volunteer@example.com" }
    }.not_to change(EventVolunteer, :count)
  end
end
