require "rails_helper"

RSpec.describe Vote::EventLinker do
  subject(:linker) { described_class.new(event, client: client) }

  let(:event) { create(:event, slug: "sunbeam-vote") }
  let(:client) { instance_double(Vote::Client, configured?: true) }

  let(:created_body) do
    {
      "id" => "vote-evt-1",
      "slug" => "sunbeam-vote",
      "adminUrl" => "https://vote.hackclub.com/admin/vote-evt-1",
      "galleryUrl" => "https://vote.hackclub.com/vote-evt-1"
    }
  end

  def attach_artwork
    png = file_fixture("headshot.png").binread
    event.logo.attach(io: StringIO.new(png), filename: "logo.png", content_type: "image/png")
    event.banner.attach(io: StringIO.new(png), filename: "banner.png", content_type: "image/png")
  end

  it "creates the vote event and records the linkage" do
    attach_artwork
    admin = User.create!(email: "vote-admin@example.com", name: "Vote Admin")
    EventRoleAssignment.create!(user: admin, event: event, role: "event_admin")
    allow(client).to receive(:find_event).with("sunbeam-vote").and_return(nil)
    allow(client).to receive(:create_event).and_return(created_body)

    result = linker.call

    expect(result.status).to eq(:created)
    expect(result).to be_linked
    expect(event.reload.vote_event_id).to eq("vote-evt-1")
    expect(event.vote_event_gallery_url).to eq("https://vote.hackclub.com/vote-evt-1")
    expect(client).to have_received(:create_event).with(
      hash_including(
        name: event.name,
        slug: "sunbeam-vote",
        # vote.hackclub.com fetches the images itself, so they point at the
        # deployed host rather than whatever host served this request.
        logo_url: a_string_starting_with("https://"),
        background_url: a_string_starting_with("https://"),
        admins: [ "vote-admin@example.com" ]
      )
    )
  end

  it "only offers Attend event admins as vote admins" do
    attach_artwork
    ops = User.create!(email: "vote-ops@example.com", name: "Ops")
    EventRoleAssignment.create!(user: ops, event: event, role: "ops")
    allow(client).to receive(:find_event).and_return(nil)
    allow(client).to receive(:create_event).and_return(created_body)

    linker.call

    expect(client).to have_received(:create_event).with(hash_including(admins: []))
  end

  it "adopts an existing vote event with the same slug instead of duplicating it" do
    attach_artwork
    allow(client).to receive(:find_event).with("sunbeam-vote").and_return(created_body)
    allow(client).to receive(:create_event)

    result = linker.call

    expect(result.status).to eq(:linked_existing)
    expect(result).to be_linked
    expect(event.reload.vote_event_id).to eq("vote-evt-1")
    expect(client).not_to have_received(:create_event)
  end

  it "adopts the winner when it loses the create race" do
    attach_artwork
    allow(client).to receive(:find_event).with("sunbeam-vote").and_return(nil, created_body)
    allow(client).to receive(:create_event).and_raise(Vote::Error.new("Slug taken", status: 409))

    result = linker.call

    expect(result.status).to eq(:linked_existing)
    expect(event.reload.vote_event_id).to eq("vote-evt-1")
  end

  it "refuses without both a logo and a banner" do
    allow(client).to receive(:find_event).and_return(nil)
    allow(client).to receive(:create_event)

    result = linker.call

    expect(result.status).to eq(:missing_artwork)
    expect(result).not_to be_linked
    expect(client).not_to have_received(:create_event)
  end

  it "says so when the event is already linked, without calling out at all" do
    event.link_vote_event!(created_body)
    allow(client).to receive(:find_event)

    result = linker.call

    expect(result.status).to eq(:already_linked)
    expect(result).to be_linked
    expect(client).not_to have_received(:find_event)
  end

  it "says so when the server has no vote.hackclub.com key" do
    allow(client).to receive(:configured?).and_return(false)
    allow(client).to receive(:find_event)

    result = linker.call

    expect(result.status).to eq(:not_configured)
    expect(client).not_to have_received(:find_event)
  end

  it "surfaces any other failure with the API's own message" do
    attach_artwork
    allow(client).to receive(:find_event).and_return(nil)
    allow(client).to receive(:create_event).and_raise(Vote::Error.new("Name is required", status: 422))

    result = linker.call

    expect(result.status).to eq(:failed)
    expect(result.message).to eq("vote.hackclub.com: Name is required")
    expect(event.reload.vote_event_id).to be_nil
  end
end
