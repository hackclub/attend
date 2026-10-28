require "rails_helper"

RSpec.describe RoomingContext, type: :model do
  let(:event) { create(:event) }
  let(:main_stay) { event.main_rooming_context }
  let(:post_event) { event.rooming_contexts.create!(name: "Post-event night", kind: :post_event) }

  def registered_with_accommodation(exempt: false)
    create(:participant_event, event: event, status: "complete").tap do |pe|
      pe.create_accommodation!(rooming_exempt: exempt)
    end
  end

  describe "Event#main_rooming_context" do
    it "creates the main stay once and then returns it" do
      expect { main_stay }.to change(described_class, :count).by(1)
      expect(event.main_rooming_context).to eq(main_stay)
      expect(main_stay).to be_main
      expect(main_stay).to be_everyone
    end

    it "allows only one main stay per event" do
      main_stay
      duplicate = event.rooming_contexts.build(name: "Another main", kind: :main)

      expect(duplicate).not_to be_valid
    end
  end

  describe "Event#rooming_plan" do
    it "returns the main stay's plan without creating anything" do
      expect(event.rooming_plan).to be_nil
      expect(described_class.count).to eq(0)

      plan = main_stay.create_rooming_plan!(event: event, room_capacity: 2)

      expect(event.rooming_plan).to eq(plan)
    end
  end

  describe "rooms" do
    it "default to the main stay when only the event is given" do
      room = event.rooms.create!(capacity: 2)

      expect(room.rooming_context).to eq(main_stay)
    end

    it "can't belong to another event's stay" do
      other_stay = create(:event).main_rooming_context
      room = event.rooms.build(capacity: 2, rooming_context: other_stay)

      expect(room).not_to be_valid
      expect(room.errors[:rooming_context]).to be_present
    end

    it "can reuse a name across stays but not within one" do
      main_stay.rooms.create!(name: "101", capacity: 2)

      expect(post_event.rooms.build(name: "101", capacity: 2)).to be_valid
      expect(main_stay.rooms.build(name: "101", capacity: 2)).not_to be_valid
    end
  end

  describe "room assignments" do
    let(:participant_event) { registered_with_accommodation }
    let(:main_room) { main_stay.rooms.create!(capacity: 2) }
    let(:post_room) { post_event.rooms.create!(capacity: 2) }

    it "let one person hold a room in each stay" do
      main_assignment = RoomAssignment.create!(room: main_room, participant_event: participant_event)
      post_assignment = RoomAssignment.create!(room: post_room, participant_event: participant_event)

      expect(main_assignment.rooming_context).to eq(main_stay)
      expect(post_assignment.rooming_context).to eq(post_event)
      expect(participant_event.room_assignments).to contain_exactly(main_assignment, post_assignment)
    end

    it "allow only one room per person per stay" do
      RoomAssignment.create!(room: main_room, participant_event: participant_event)
      second = RoomAssignment.new(room: main_stay.rooms.create!(capacity: 2), participant_event: participant_event)

      expect(second).not_to be_valid
      expect(second.errors[:participant_event_id]).to include("is already assigned to a room for this stay")
    end

    it "expose only the main-stay room as the participant's room" do
      post_assignment = RoomAssignment.create!(room: post_room, participant_event: participant_event)
      expect(participant_event.reload.room_assignment).to be_nil

      main_assignment = RoomAssignment.create!(room: main_room, participant_event: participant_event)
      participant_event.reload

      expect(participant_event.room_assignment).to eq(main_assignment)
      expect(participant_event.room).to eq(main_room)
      expect(post_assignment).to be_persisted
    end
  end

  describe "participant pools" do
    let!(:rooming) { registered_with_accommodation }
    let!(:exempt) { registered_with_accommodation(exempt: true) }
    let!(:no_accommodation) { create(:participant_event, event: event, status: "complete") }

    it "puts everyone with accommodation in an everyone stay, minus exemptions for beds" do
      expect(main_stay.participant_events).to contain_exactly(rooming, exempt)
      expect(main_stay.assignable_participant_events).to contain_exactly(rooming)
      expect(main_stay.exempt_participant_events).to contain_exactly(exempt)
    end

    it "keeps an eligible-only stay empty until people are put on its list" do
      expect(post_event).to be_eligible_only
      expect(post_event.participant_events).to be_empty
      expect(post_event.assignable_participant_events).to be_empty
    end
  end

  it "rejects an end date before the start date" do
    stay = event.rooming_contexts.build(name: "Pre-event", kind: :pre_event, starts_on: Date.new(2026, 11, 2), ends_on: Date.new(2026, 11, 1))

    expect(stay).not_to be_valid
    expect(stay.errors[:ends_on]).to be_present
  end
end
