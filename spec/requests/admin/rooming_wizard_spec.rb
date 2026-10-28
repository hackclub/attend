require "rails_helper"

RSpec.describe "Admin::RoomingWizard", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-rooming@example.com", name: "Admin", global_role: "global_admin", admin_console_beta: false) }
  let(:event) { create(:event) }
  let!(:rooming_plan) do
    event.main_rooming_context.create_rooming_plan!(event: event, created_by_user: admin, room_capacity: 2, status: :draft)
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
      room = event.main_rooming_context.rooms.create!(capacity: 2)
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
    let!(:room) { event.main_rooming_context.rooms.create!(capacity: 2) }
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

  # A post-event stay sits alongside the main stay. Until the wizard has a
  # stay switcher it's reached with /stays/:stay_id, and nothing done in one stay
  # may touch the other's rooms.
  describe "with a post-event stay" do
    let(:post_event) { event.rooming_contexts.create!(name: "Post-event night", kind: :post_event, enrollment: :everyone) }
    let!(:participant_event) do
      create(:participant_event, event: event, status: "complete").tap { |pe| pe.create_accommodation!(gender_identity: "female") }
    end
    let!(:main_room) { event.main_rooming_context.rooms.create!(capacity: 2) }
    let!(:post_room) { post_event.rooms.create!(capacity: 2) }

    it "moves someone into a post-event room without taking their main-stay room" do
      main_assignment = RoomAssignment.create!(room: main_room, participant_event: participant_event)

      post move_assignment_admin_event_rooming_wizard_path(event.slug, stay_id: post_event.id),
        params: { participant_event_id: participant_event.id, room_id: post_room.id },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      expect(main_assignment.reload.room).to eq(main_room)
      expect(participant_event.room_assignments.find_by(rooming_context: post_event).room).to eq(post_room)
    end

    { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
      it "keeps the wizard's own links inside the stay #{ui}" do
        admin.update!(admin_console_beta: console)

        get assignments_admin_event_rooming_wizard_path(event.slug, stay_id: post_event.id)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(move_assignment_admin_event_rooming_wizard_path(event.slug, stay_id: post_event.id))
        expect(response.body).not_to include(%("#{move_assignment_admin_event_rooming_wizard_path(event.slug)}"))
      end
    end

    it "won't put someone in another stay's room" do
      post move_assignment_admin_event_rooming_wizard_path(event.slug),
        params: { participant_event_id: participant_event.id, room_id: post_room.id },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      # Not-found is handled app-wide with a redirect.
      expect(response).to have_http_status(:redirect)
      expect(RoomAssignment.count).to eq(0)
    end

    it "auto-assigns the main stay without clearing post-event assignments" do
      post_assignment = RoomAssignment.create!(room: post_room, participant_event: participant_event)

      post auto_assign_admin_event_rooming_wizard_path(event.slug)

      expect(post_assignment.reload.room).to eq(post_room)
      expect(participant_event.reload.room_assignment.rooming_context).to be_main
      expect(post_event.rooms.reload).to contain_exactly(post_room)
    end

    it "exports only the requested stay's rooms" do
      main_room.update!(name: "Main 101")
      post_room.update!(name: "Post 201")
      RoomAssignment.create!(room: post_room, participant_event: participant_event)

      get export_csv_admin_event_rooming_wizard_path(event.slug, stay_id: post_event.id, format: :csv)

      expect(response.body).to include("Post 201")
      expect(response.body).not_to include("Main 101")
    end
  end

  describe "GET finalize" do
    let(:stay) { event.main_rooming_context }
    let(:room) { stay.rooms.create!(capacity: 3) }

    def tokens
      Nokogiri::HTML(response.body).css("span.rounded-full").to_h { |token| [ token.text[/\A\s*(\S+)/, 1], token[:class] ] }
    end

    def roomed(first_name)
      create(:participant_event, event: event, participant: create(:participant, legal_first_name: first_name)).tap do |pe|
        RoomAssignment.create!(room: room, participant_event: pe)
      end
    end

    it "shows people scanned at the stay's own check-in point as arrived" do
      other_hotel = event.scan_contexts.create!(name: "Other hotel", kind: "lodging")
      arrived = roomed("Arrived")
      elsewhere = roomed("Elsewhere")
      Scan.create!(participant_event: arrived, scan_context: stay.scan_context, user: admin, scanned_at: Time.current)
      Scan.create!(participant_event: elsewhere, scan_context: other_hotel, user: admin, scanned_at: Time.current)

      get finalize_admin_event_rooming_wizard_path(event.slug)

      expect(response).to have_http_status(:ok)
      expect(tokens.fetch("Arrived")).to include("bg-green-100")
      expect(tokens.fetch("Elsewhere")).not_to include("bg-green-100")
    end

    it "falls back to any Lodging point for a stay without its own" do
      stay.scan_context.destroy!
      lodging = event.scan_contexts.create!(name: "Hotel lobby", kind: "lodging")
      lunch = event.scan_contexts.create!(name: "Lunch", kind: "tracking_only")
      arrived = roomed("Arrived")
      lunching = roomed("Lunching")
      Scan.create!(participant_event: arrived, scan_context: lodging, user: admin, scanned_at: Time.current)
      Scan.create!(participant_event: lunching, scan_context: lunch, user: admin, scanned_at: Time.current)

      get finalize_admin_event_rooming_wizard_path(event.slug)

      expect(response).to have_http_status(:ok)
      expect(tokens.fetch("Arrived")).to include("bg-green-100")
      expect(tokens.fetch("Lunching")).not_to include("bg-green-100")
    end
  end
end
