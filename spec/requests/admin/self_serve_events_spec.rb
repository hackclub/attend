require "rails_helper"

# Holders of the attend-self-serve-events entitlement in the HCA directory,
# which reaches Attend as the `groups` claim (see User#self_serve_event_creator?).
RSpec.describe "Self-serve event creation", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event_params) { { name: "Self Serve Con", slug: "self-serve-con", support_email: "selfserve@hackclub.com" } }
  let(:creator) do
    create(:user, email: "organizer@example.com",
      oidc_claims: { "groups" => [ User::SELF_SERVE_EVENTS_GROUP ] })
  end

  [ true ].each do |console|
    context "with the admin console #{console ? 'on' : 'off'}" do
      before do
        sign_in creator
      end

      it "opens the admin and the new event form to someone who staffs nothing yet" do
        get admin_root_path
        expect(response).to have_http_status(:ok)

        get admin_new_event_path
        expect(response).to have_http_status(:ok)
      end

      it "creates a standalone event and makes them its admin" do
        post admin_events_path, params: { event: event_params }

        event = Event.find_by!(slug: "self-serve-con")
        expect(response).to redirect_to(admin_event_setup_schedule_path(event))
        expect(event.event_series).to be_nil
        expect(creator.event_admin_for?(event)).to be(true)
      end
    end
  end

  before { sign_in creator }

  it "still needs membership to put the event in a series" do
    series = create(:event_series)

    post admin_events_path, params: { event: event_params.merge(event_series_id: series.id) }

    expect(Event.find_by(slug: "self-serve-con")).to be_nil
  end

  it "doesn't show them anyone else's events" do
    create(:event, slug: "someone-elses-con")

    get admin_root_path

    expect(response.body).not_to include("someone-elses-con")
  end

  it "turns away someone whose groups don't include the entitlement" do
    creator.update!(oidc_claims: { "groups" => [ "some-other-entitlement" ] })

    get admin_root_path
    expect(response).to redirect_to(root_path)

    post admin_events_path, params: { event: event_params }
    expect(Event.find_by(slug: "self-serve-con")).to be_nil
  end
end
