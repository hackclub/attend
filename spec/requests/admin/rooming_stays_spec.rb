require "rails_helper"

RSpec.describe "Admin rooming stays and rosters", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-stays@example.com", name: "Admin", global_role: "global_admin", admin_console_beta: false) }
  let(:event) { create(:event, accommodation_enabled: true) }

  before { sign_in admin }

  def registered(email)
    participant = create(:participant, email: email)
    create(:participant_event, event: event, participant: participant, status: :complete).tap(&:create_accommodation!)
  end

  { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
    context ui do
      before { admin.update!(admin_console_beta: console) }

      it "lists every stay, the one during the event included" do
        event.main_rooming_context
        event.rooming_contexts.create!(name: "Night after", kind: :post_event)

        get admin_event_rooming_stays_path(event.slug)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(RoomingContext::MAIN_NAME)
        expect(response.body).to include("Night after")
        expect(response.body).to include("Add stay")
      end

      it "tabs between stays in the rooming wizard" do
        event.main_rooming_context
        event.rooming_contexts.create!(name: "Night after", kind: :post_event)

        get setup_admin_event_rooming_wizard_path(event.slug)

        expect(response.body).to include(RoomingContext::MAIN_NAME)
        expect(response.body).to include("Night after")
      end

      it "shows a stay's roster page" do
        stay = event.rooming_contexts.create!(name: "Post-event night", kind: :post_event)
        stay.roster_entries.create!(participant_event: registered("quiet.heron@example.com"))

        get admin_event_rooming_stay_roster_entries_path(event.slug, stay)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("who's staying")
      end

      it "shows the setup wizard's accommodation step" do
        get admin_event_setup_stays_path(event)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Add stay")
      end

      it "re-renders the stay form with errors" do
        post admin_event_rooming_stays_path(event.slug), params: { rooming_context: { name: "" } }

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe "adding a stay" do
    it "creates a list-only stay with its options, skipping blank rows" do
      post admin_event_rooming_stays_path(event.slug), params: { rooming_context: {
        name: "Post-event night", kind: "post_event", enrollment: "eligible_only", starts_on: "2026-11-02", ends_on: "2026-11-03",
        eligibility_options_attributes: {
          "0" => { label: "Bought it in the shop", price: "40" },
          "1" => { label: "Other", price: "" },
          "2" => { label: "", price: "" }
        }
      } }

      stay = event.rooming_contexts.find_by!(name: "Post-event night")
      expect(response).to redirect_to(admin_event_rooming_stays_path(event.slug))
      expect(stay).to be_eligible_only
      expect(stay.eligibility_options.map { |o| [ o.label, o.price_cents ] }).to eq([ [ "Bought it in the shop", 4000 ], [ "Other", nil ] ])
    end

    it "needs no eligibility options at all" do
      post admin_event_rooming_stays_path(event.slug), params: { rooming_context: { name: "Pre-event night", kind: "pre_event", enrollment: "eligible_only" } }

      expect(event.rooming_contexts.find_by!(name: "Pre-event night").eligibility_options).to be_empty
    end

    it "goes back to the setup wizard when added from there" do
      post admin_event_rooming_stays_path(event.slug), params: { return_to: "setup", rooming_context: { name: "Pre-event night", kind: "pre_event" } }

      expect(response).to redirect_to(admin_event_setup_stays_path(event))
    end

    it "removes the stay during the event like any other, rooms and all" do
      during = event.main_rooming_context
      room = during.rooms.create!(capacity: 2)
      RoomAssignment.create!(room: room, participant_event: registered("venue.sleeper@example.com"))

      delete admin_event_rooming_stay_path(event.slug, during)

      expect(RoomingContext.exists?(during.id)).to be(false)
      expect(Room.exists?(room.id)).to be(false)
    end

    it "offers the stay during the event first, then the night after" do
      get admin_event_rooming_stays_path(event.slug)
      expect(response.body).to include(%(value="#{RoomingContext::MAIN_NAME}"))

      event.main_rooming_context
      get admin_event_rooming_stays_path(event.slug)
      expect(response.body).not_to include(%(value="#{RoomingContext::MAIN_NAME}"))
      expect(response.body).to match(/<option selected="selected" value="post_event">/)
    end

    it "only allows one stay during the event" do
      event.main_rooming_context

      post admin_event_rooming_stays_path(event.slug), params: { rooming_context: { name: "Second hotel", kind: "main", enrollment: "everyone" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("already has a during-the-event stay")
    end

    it "lets the stay during the event be list-only" do
      post admin_event_rooming_stays_path(event.slug), params: { rooming_context: { name: "Hotel", kind: "main", enrollment: "eligible_only" } }

      expect(event.rooming_contexts.find_by!(name: "Hotel")).to be_eligible_only
    end

    it "sends the rooming wizard to the accommodation page when there are no stays" do
      get admin_event_rooming_wizard_path(event.slug)

      expect(response).to redirect_to(admin_event_rooming_stays_path(event.slug))
      expect(RoomingContext.count).to eq(0)
    end
  end

  describe "the roster" do
    let(:stay) { event.rooming_contexts.create!(name: "Post-event night", kind: :post_event) }

    it "adds picked people with no reason given" do
      pe = registered("sleepy.otter@example.com")

      post admin_event_rooming_stay_roster_entries_path(event.slug, stay), params: { mode: "participants", participant_event_ids: [ pe.id ], eligibility_option_id: "" }

      entry = stay.roster_entries.sole
      expect(entry.participant_event).to eq(pe)
      expect(entry.eligibility_option).to be_nil
      expect(entry).to be_source_manual
      expect(entry.added_by_user).to eq(admin)
    end

    it "adds pasted emails and lists the ones that aren't registered" do
      option = stay.eligibility_options.create!(label: "Bought it in the shop")
      pe = registered("Sleepy.Otter@example.com")

      post admin_event_rooming_stay_roster_entries_path(event.slug, stay), params: {
        mode: "emails", eligibility_option_id: option.id,
        emails: "email,order\nsleepy.otter@example.com,1001\nlost.badger@example.com,1002\n"
      }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("lost.badger@example.com")
      expect(stay.roster_entries.sole).to have_attributes(participant_event_id: pe.id, eligibility_option: option, source: "csv")
    end

    it "adds a group" do
      event.update!(groups_enabled: true)
      group = event.groups.create!(name: "Hardware")
      pe = registered("busy.beaver@example.com")
      GroupMembership.create!(group: group, participant_event: pe)

      post admin_event_rooming_stay_roster_entries_path(event.slug, stay), params: { mode: "group", group_id: group.id }

      expect(stay.roster_entries.sole).to have_attributes(participant_event_id: pe.id, source: "group")
    end

    it "takes someone off and frees their room in that stay only" do
      pe = registered("night.owl@example.com")
      entry = stay.roster_entries.create!(participant_event: pe)
      post_room = stay.rooms.create!(capacity: 2)
      main_room = event.main_rooming_context.rooms.create!(capacity: 2)
      RoomAssignment.create!(room: post_room, participant_event: pe)
      RoomAssignment.create!(room: main_room, participant_event: pe)

      delete admin_event_rooming_stay_roster_entry_path(event.slug, stay, entry)

      expect(response).to redirect_to(admin_event_rooming_stay_roster_entries_path(event.slug, stay))
      expect(stay.roster_entries.reload).to be_empty
      expect(post_room.room_assignments.reload).to be_empty
      expect(main_room.room_assignments.reload.map(&:participant_event)).to eq([ pe ])
    end

    it "makes roster people the stay's rooming pool" do
      on_list = registered("on.list@example.com")
      registered("not.on.list@example.com")
      stay.roster_entries.create!(participant_event: on_list)

      expect(stay.assignable_participant_events).to contain_exactly(on_list)
    end
  end
end
