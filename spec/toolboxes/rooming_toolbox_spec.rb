require "rails_helper"

# The rooming tools work on one stay at a time and never create a stay: an
# event may have none (everyone sleeps at the venue), and organizers add them.
RSpec.describe RoomingToolbox do
  let(:event) { create(:event) }
  let(:admin) { create(:user, global_role: "global_admin") }

  def run(action, params = {})
    toolbox = described_class.new(params: params.transform_keys(&:to_s))
    allow(toolbox).to receive(:current_user).and_return(admin)
    allow(toolbox).to receive(:current_event).and_return(event)
    catch(:halt) { toolbox.public_send(action) }
    toolbox
  end

  def text(toolbox) = toolbox.instance_variable_get(:@_response)[:content].first[:text]
  def payload(toolbox) = JSON.parse(text(toolbox), symbolize_names: true)

  def registered
    create(:participant_event, event: event, status: :complete)
  end

  context "with no stays" do
    it "says so in the overview without creating one" do
      result = payload(run(:overview))

      expect(result[:stays]).to eq([])
      expect(result[:note]).to include("no stays")
      expect(RoomingContext.count).to eq(0)
    end

    it "refuses to create a room rather than creating a stay" do
      expect(text(run(:create_room, name: "101"))).to include("no stays")

      expect(RoomingContext.count).to eq(0)
      expect(Room.count).to eq(0)
    end
  end

  context "with a stay during the event and a night after" do
    let!(:during) { event.main_rooming_context }
    let!(:night_after) { event.rooming_contexts.create!(name: "Night after", kind: :post_event) }

    it "defaults to the stay during the event and lists every stay" do
      during.rooms.create!(name: "101", capacity: 2)

      result = payload(run(:overview))

      expect(result[:stays].map { |s| s[:name] }).to eq([ RoomingContext::MAIN_NAME, "Night after" ])
      expect(result[:stay][:id]).to eq(during.id)
      expect(result[:rooms].map { |r| r[:name] }).to eq([ "101" ])
    end

    it "works on the stay it's given" do
      run(:create_room, stay_id: night_after.id, name: "204")

      expect(night_after.rooms.pluck(:name)).to eq([ "204" ])
      expect(during.rooms).to be_empty
    end

    it "lists only people on a list-only stay's list as needing a room there" do
      listed = registered
      registered
      night_after.roster_entries.create!(participant_event: listed)

      result = payload(run(:overview, stay_id: night_after.id))

      expect(result[:unassigned].map { |p| p[:participant_event_id] }).to eq([ listed.id ])
    end

    it "bulk-assigns into one stay, adding people to a list-only stay's list" do
      pe = registered
      main_room = during.rooms.create!(name: "101", capacity: 2)
      RoomAssignment.create!(room: main_room, participant_event: pe)

      result = payload(run(:bulk_assign, stay_id: night_after.id, assignments: [ { room_name: "204", participant_event_ids: [ pe.id ] } ]))

      expect(result[:assigned]).to eq(1)
      expect(pe.room_assignments.map { |a| a.room.name }).to contain_exactly("101", "204")
      expect(night_after.roster_entries.pluck(:participant_event_id)).to eq([ pe.id ])
    end

    it "unassigns only in the given stay" do
      pe = registered
      RoomAssignment.create!(room: during.rooms.create!(capacity: 2), participant_event: pe)
      night_after.roster_entries.create!(participant_event: pe)
      RoomAssignment.create!(room: night_after.rooms.create!(capacity: 2), participant_event: pe)

      run(:unassign, stay_id: night_after.id, participant_event_id: pe.id)

      expect(pe.room_assignments.reload.map(&:rooming_context)).to eq([ during ])
    end
  end

  context "with several stays and none during the event" do
    before do
      event.rooming_contexts.create!(name: "Night before", kind: :pre_event)
      event.rooming_contexts.create!(name: "Night after", kind: :post_event)
    end

    it "asks for a stay_id instead of guessing" do
      expect(payload(run(:overview))[:note]).to include("stay_id")
      expect(text(run(:create_room, name: "101"))).to include("pass stay_id")
      expect(Room.count).to eq(0)
    end
  end
end
