require "rails_helper"

# The roster API is what a shop calls when someone buys a pre- or post-event
# night: find the stay, add the buyer by email with the matching option, and
# take them off again on a refund.
RSpec.describe "API v1 stay rosters", type: :request do
  let(:event) { create(:event) }
  let(:other_event) { create(:event) }
  let(:token_owner) { User.create!(email: "roster-api-owner@example.com", name: "Token Owner", global_role: "global_admin") }
  let(:api_key) { EventApiToken.generate_for(event, user: token_owner, name: "night-shop").token }
  let(:headers) { { "Authorization" => "Bearer #{api_key}" } }

  let(:post_event) { event.rooming_contexts.create!(name: "Post-event night", kind: :post_event, ends_on: Date.new(2026, 11, 3)) }
  let!(:shop_option) { post_event.eligibility_options.create!(label: "Bought it in the shop", price: "40") }
  let(:buyer) { create(:participant, email: "Night.Owl@example.com") }
  let!(:registration) do
    create(:participant_event, event: event, participant: buyer, status: :complete).tap(&:create_accommodation!)
  end

  describe "GET /api/v1/events/:event_id/stays" do
    it "lists stays with their options" do
      event.main_rooming_context
      post_event

      get api_v1_event_stays_path(event), headers: headers

      expect(response).to have_http_status(:ok)
      stays = response.parsed_body["stays"]
      expect(stays.map { |s| s["kind"] }).to eq(%w[main post_event])
      expect(stays.last["eligibility_options"]).to eq([ { "id" => shop_option.id, "label" => "Bought it in the shop", "price_cents" => 4000 } ])
    end

    it "refuses another event's key" do
      other_key = EventApiToken.generate_for(other_event, user: token_owner, name: "other-shop").token

      get api_v1_event_stays_path(event), headers: { "Authorization" => "Bearer #{other_key}" }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/events/:event_id/stays/:stay_id/roster" do
    def add(params)
      post api_v1_event_stay_roster_index_path(event, post_event), params: params, headers: headers
    end

    it "adds a registered buyer by email, case-blind, with the option label and order id" do
      expect { add(email: "night.owl@EXAMPLE.com", eligibility_option: "bought it in the shop", external_reference: "order-1001") }
        .to change(RoomingRosterEntry, :count).by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["participant_event_id"]).to eq(registration.id)
      expect(body["eligibility_option"]["id"]).to eq(shop_option.id)
      expect(body["source"]).to eq("api")
      expect(body["external_reference"]).to eq("order-1001")
      expect(body["in_rooming_pool"]).to be(true)
      expect(post_event.participant_events).to contain_exactly(registration)
      expect(AuditLog.where(record: RoomingRosterEntry.last, action: :record_create)).to exist
    end

    it "treats a repeat as an update rather than a duplicate" do
      add(email: buyer.email, eligibility_option_id: shop_option.id)

      expect { add(email: buyer.email, external_reference: "order-1002") }.not_to change(RoomingRosterEntry, :count)

      expect(response).to have_http_status(:ok)
      entry = RoomingRosterEntry.sole
      expect(entry.external_reference).to eq("order-1002")
      expect(entry.eligibility_option).to eq(shop_option)
    end

    it "says so when the email isn't registered for the event" do
      add(email: "nobody-here@example.com")

      expect(response).to have_http_status(:not_found)
      expect(RoomingRosterEntry.count).to eq(0)
    end

    it "won't add someone registered for a different event" do
      stranger = create(:participant_event, event: other_event)

      add(participant_event_id: stranger.id)

      expect(response).to have_http_status(:not_found)
    end

    it "rejects an option the stay doesn't have" do
      add(email: buyer.email, eligibility_option: "Free upgrade")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Bought it in the shop")
      expect(RoomingRosterEntry.count).to eq(0)
    end

    it "refuses the main stay, which already includes everyone" do
      post api_v1_event_stay_roster_index_path(event, event.main_rooming_context), params: { email: buyer.email }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "lets a global token scoped to rooming:write in, but not one scoped elsewhere" do
      scoped = GlobalApiToken.generate_for(token_owner, scopes: [ "rooming:write" ])
      other = GlobalApiToken.generate_for(token_owner, scopes: [ "bans:write" ])

      post api_v1_event_stay_roster_index_path(event, post_event), params: { email: buyer.email }, headers: { "Authorization" => "Bearer #{other.token}" }
      expect(response).to have_http_status(:forbidden)

      post api_v1_event_stay_roster_index_path(event, post_event), params: { email: buyer.email }, headers: { "Authorization" => "Bearer #{scoped.token}" }
      expect(response).to have_http_status(:created)
    end
  end

  describe "GET and DELETE on the roster" do
    let!(:entry) { post_event.roster_entries.create!(participant_event: registration, source: :api, external_reference: "order-1001") }

    it "finds an entry by order id" do
      get api_v1_event_stay_roster_index_path(event, post_event, external_reference: "order-1001"), headers: headers

      expect(response.parsed_body["roster"].map { |e| e["id"] }).to eq([ entry.id ])
    end

    it "removes someone on refund and frees their room in that stay" do
      room = post_event.rooms.create!(capacity: 2)
      RoomAssignment.create!(room: room, participant_event: registration)

      delete api_v1_event_stay_roster_path(event, post_event, entry), headers: headers

      expect(response).to have_http_status(:no_content)
      expect(RoomingRosterEntry.count).to eq(0)
      expect(room.room_assignments.reload).to be_empty
    end
  end
end
