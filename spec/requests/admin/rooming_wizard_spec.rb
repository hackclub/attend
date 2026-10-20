require "rails_helper"

RSpec.describe "Admin::RoomingWizard", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-rooming@example.com", name: "Admin", global_role: "global_admin", admin_console_beta: false) }
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

    context "with the admin console beta" do
      before { admin.update!(admin_console_beta: true) }

      it "offers sentence-case manual assignment without auto-assigning" do
        get preferences_admin_event_rooming_wizard_path(event.slug)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Assign manually")
        expect(response.body).to include(manual_assign_admin_event_rooming_wizard_path(event.slug))
      end
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

  # A `replace` swaps out the target element itself, so the streamed template's
  # root must carry the target's id or every later stream at that id no-ops.
  # An `update` keeps the target and only swaps its contents.
  describe "assignments board turbo streams" do
    let(:turbo_headers) { { "Accept" => "text/vnd.turbo-stream.html" } }
    let!(:room) { event.rooms.create!(capacity: 2) }
    let!(:participant_event) do
      create(:participant_event, event: event).tap(&:create_accommodation!)
    end

    def streams
      Nokogiri::HTML5.fragment(response.body).css("turbo-stream")
    end

    def expect_targets_survive(*targets)
      expect(streams.map { |s| s["target"] }).to include(*targets)

      streams.each do |stream|
        next unless stream["action"] == "replace"

        # The room card partial ships a trailing <script>, so ignore those.
        roots = stream.at_css("template").children.select(&:element?).reject { |el| el.name == "script" }
        expect(roots.map { |el| el["id"] }).to eq([ stream["target"] ]),
          "replace of ##{stream["target"]} would drop the target id"
      end
    end

    def rooms_container_stream
      streams.find { |s| s["target"] == "rooms_container" }
    end

    # The original and console assignments boards both wrap the room list in
    # #rooms_container > #rooms_list, so the streams must hold for either UI.
    { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
      context ui do
        before { admin.update!(admin_console_beta: console) }

        it "keeps #rooms_container after a participant is moved into a room" do
          post move_assignment_admin_event_rooming_wizard_path(event.slug),
            params: { participant_event_id: participant_event.id, room_id: room.id },
            headers: turbo_headers

          expect(response).to have_http_status(:ok)
          expect(rooms_container_stream["action"]).to eq("update")
          expect(rooms_container_stream.at_css("template #rooms_list #room_#{room.id}[data-room-id='#{room.id}']")).to be_present
          expect_targets_survive("summary_bar", "unassigned_sidebar", "rooms_container")
        end

        it "keeps #rooms_container after toggling an exemption" do
          post toggle_exempt_admin_event_rooming_wizard_path(event.slug),
            params: { participant_event_id: participant_event.id },
            headers: turbo_headers

          expect(response).to have_http_status(:ok)
          expect(rooms_container_stream["action"]).to eq("update")
          expect_targets_survive("summary_bar", "unassigned_sidebar", "rooms_container")
        end

        it "keeps the room card id when a room is updated" do
          patch update_room_admin_event_rooming_wizard_path(event.slug),
            params: { room_id: room.id, name: "Room Narwhal" },
            headers: turbo_headers

          expect(response).to have_http_status(:ok)
          expect_targets_survive("summary_bar", "room_#{room.id}")
        end

        it "keeps the room card id when staff are added" do
          post add_staff_admin_event_rooming_wizard_path(event.slug),
            params: { room_id: room.id, staff_name: "Captain Placeholder" },
            headers: turbo_headers

          expect(response).to have_http_status(:ok)
          expect_targets_survive("summary_bar", "room_#{room.id}")
        end

        it "renders #rooms_container exactly once on the initial page" do
          get assignments_admin_event_rooming_wizard_path(event.slug)

          page = Nokogiri::HTML5(response.body)
          expect(page.css("#rooms_container").size).to eq(1)
          expect(page.css("#rooms_container > #rooms_list").size).to eq(1)
        end
      end
    end
  end

  describe "POST link_preference" do
    { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
      context ui do
        before { admin.update!(admin_console_beta: console) }

        it "updates the preference links wrapper instead of replacing it" do
          participant_event = create(:participant_event, event: event).tap(&:create_accommodation!)
          target = create(:participant_event, event: event).tap(&:create_accommodation!)

          post link_preference_admin_event_rooming_wizard_path(event.slug),
            params: { participant_event_id: participant_event.id, target_participant_event_id: target.id, kind: "preference", rank: 1 },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

          stream = Nokogiri::HTML5.fragment(response.body).at_css("turbo-stream[target='preference_links_#{participant_event.id}']")
          expect(stream["action"]).to eq("update")
        end
      end
    end
  end
end
