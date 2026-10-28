require "rails_helper"

# Once an event has more than one stay, a person can have a room in each.
# Everywhere that used to show "the room" shows all of them, labelled by stay,
# except that a room in the stay during the event stays unlabelled so events
# with only that stay read the way they always have.
RSpec.describe "Rooms per stay", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, accommodation_enabled: true) }
  let(:during) { event.main_rooming_context }
  let(:night_after) { event.rooming_contexts.create!(name: "Night after", kind: :post_event) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user, legal_first_name: "Robin", legal_last_name: "Wren", date_of_birth: 17.years.ago) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress,
      onboarding_step: 99, onboarding_intro_seen_at: Time.current).tap(&:create_accommodation!)
  end
  let(:hotel_room) { during.rooms.create!(name: "101", capacity: 2) }
  let(:night_after_room) { night_after.rooms.create!(name: "204", capacity: 2) }

  def room_everywhere
    RoomAssignment.create!(room: hotel_room, participant_event: participant_event)
    night_after.roster_entries.create!(participant_event: participant_event)
    RoomAssignment.create!(room: night_after_room, participant_event: participant_event)
  end

  describe "ParticipantEvent#room_summary" do
    it "lists every room in stay order, labelling all but the stay during the event" do
      room_everywhere

      expect(participant_event.reload.room_summary).to eq("101, 204 (Night after)")
    end

    it "reads as before for an event with only the stay during the event" do
      RoomAssignment.create!(room: hotel_room, participant_event: participant_event)

      expect(participant_event.reload.room_summary).to eq("101")
    end

    it "is blank without a room" do
      expect(participant_event.room_summary).to be_nil
    end
  end

  it "exports every room" do
    room_everywhere
    field = Exports::FieldRegistry.all.find { |f| f.key == "room.name" }

    expect(field.extractor.call(participant_event.reload)).to eq("101, 204 (Night after)")
  end

  describe "in the admin" do
    let(:admin) { User.create!(email: "admin-rooms-per-stay@example.com", name: "Admin", global_role: "global_admin") }

    before do
      room_everywhere
      sign_in admin
    end

    { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
      context ui do
        before { admin.update!(admin_console_beta: console) }

        it "shows each room on the participant table" do
          get table_admin_event_participants_path(event)

          cell = Nokogiri::HTML5(response.body).at_css("td[data-column='room']")
          expect(cell.text.squish).to eq("101 204 Night after")
        end

        it "lists the stays on the participant's page" do
          get admin_event_participant_path(event, participant_event)

          text = Nokogiri::HTML5(response.body).text.squish
          expect(text).to include("During the event: Room 101")
          expect(text).to include("Night after: Room 204")
        end
      end
    end
  end

  describe "for the participant" do
    before do
      room_everywhere
      sign_in user
    end

    it "says rooms are to be confirmed until rooming for the stay is finalized" do
      get onboarding_step_path(step: "accommodation", event_id: event.id)

      text = Nokogiri::HTML5(response.body).text.squish
      expect(text).to include("Where you're staying")
      expect(text).to include("During the event: room to be confirmed")
      expect(text).not_to include("Room 101")
    end

    it "shows the room once that stay's rooming is finalized" do
      night_after.create_rooming_plan!(room_capacity: 2).finalize!(create(:user))

      get dashboard_event_path(participant_event)

      text = Nokogiri::HTML5(response.body).text.squish
      expect(text).to include("Night after: Room 204")
      expect(text).to include("During the event: room to be confirmed")
    end

    it "leaves out a stay they're exempt from" do
      participant_event.accommodation.update!(rooming_exempt: true)
      RoomAssignment.where(room: hotel_room).destroy_all

      get dashboard_event_path(participant_event)

      text = Nokogiri::HTML5(response.body).text.squish
      expect(text).not_to include("During the event:")
      expect(text).to include("Night after: room to be confirmed")
    end
  end
end
