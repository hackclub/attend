require "rails_helper"

RSpec.describe "Admin::RoomingWizard", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-rooming@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event) }
  let!(:rooming_plan) do
    event.create_rooming_plan!(created_by_user: admin, room_capacity: 2, status: :draft)
  end

  before { sign_in admin }

  describe "GET preferences" do
    it "offers manual assignment without auto-assigning" do
      get preferences_admin_event_rooming_wizard_path(event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Assign Manually")
      expect(response.body).to include(manual_assign_admin_event_rooming_wizard_path(event.slug))
    end
  end

  describe "POST manual_assign" do
    it "continues to assignments without changing existing assignments" do
      participant_event = create(:participant_event, event: event)
      room = event.rooms.create!(capacity: 2)
      assignment = RoomAssignment.create!(room: room, participant_event: participant_event)

      expect do
        post manual_assign_admin_event_rooming_wizard_path(event.slug)
      end.not_to change(RoomAssignment, :count)

      expect(response).to redirect_to(assignments_admin_event_rooming_wizard_path(event.slug))
      expect(rooming_plan.reload).to be_preferences_linked
      expect(assignment.reload.room).to eq(room)
    end

    it "makes assignments the latest wizard step" do
      post manual_assign_admin_event_rooming_wizard_path(event.slug)

      get admin_event_rooming_wizard_path(event.slug)

      expect(response).to redirect_to(assignments_admin_event_rooming_wizard_path(event.slug))
    end
  end
end
