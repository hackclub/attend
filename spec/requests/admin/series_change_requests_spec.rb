require "rails_helper"

RSpec.describe "Admin series change requests", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:series) { create(:event_series, name: "Lanternfish") }
  let!(:first_event) { create(:event, event_series: series, name: "Lanternfish North") }
  let!(:second_event) { create(:event, event_series: series, name: "Lanternfish South") }
  let(:outside_event) { create(:event, name: "Unrelated Jam") }

  let(:owner) do
    create(:user).tap { |user| SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner") }
  end

  def change_request(event:, note:, audience: :operations, status: :pending)
    requester = create(:user)
    participant = create(:participant, user: requester)
    participant_event = create(:participant_event, event: event, participant: participant)
    RegistrationChangeRequest.create!(
      participant_event: participant_event,
      requested_by: requester,
      kind: :support,
      staff_audience: audience,
      requester_note: note,
      status: status
    )
  end

  let!(:north_request) { change_request(event: first_event, note: "Question about the north venue") }
  let!(:south_request) { change_request(event: second_event, note: "Safeguarding question at south", audience: :safeguarding) }
  let!(:approved_request) { change_request(event: second_event, note: "Already sorted out", status: :approved) }
  let!(:outside_request) { change_request(event: outside_event, note: "Not part of this series") }

  [ true, false ].each do |console|
    context "with the #{console ? 'console' : 'original'} admin" do
      before { owner.update!(admin_console_beta: console) }

      it "lists pending requests from every event in the series, linking to each event's review page" do
        sign_in owner

        get admin_series_change_requests_path(series)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Question about the north venue", "Safeguarding question at south")
        expect(response.body).to include("Lanternfish North", "Lanternfish South")
        expect(response.body).to include(admin_event_registration_change_request_path(first_event, north_request))
        expect(response.body).to include(admin_event_registration_change_request_path(second_event, south_request))
        expect(response.body).not_to include("Already sorted out")
        expect(response.body).not_to include("Not part of this series")
      end

      it "filters by status and by event" do
        sign_in owner

        get admin_series_change_requests_path(series, status: "all")
        expect(response.body).to include("Already sorted out", "Question about the north venue")

        get admin_series_change_requests_path(series, status: "all", event: second_event.slug)
        expect(response.body).to include("Already sorted out", "Safeguarding question at south")
        expect(response.body).not_to include("Question about the north venue")
      end

      it "links to the page from the series dashboard with the pending count" do
        sign_in owner

        get admin_series_path(series)

        expect(response.body).to include(admin_series_change_requests_path(series))
        expect(response.body).to match(/Change requests.{0,80}\(2\)/m)
      end
    end
  end

  it "lets series organizers see it too" do
    organizer = create(:user)
    SeriesRoleAssignment.create!(user: organizer, event_series: series, role: "organizer")
    sign_in organizer

    get admin_series_change_requests_path(series)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Question about the north venue")
  end

  it "keeps out staff who only work one of the series' events" do
    ops = create(:user)
    create(:event_role_assignment, event: first_event, user: ops, role: :ops)
    sign_in ops

    get admin_series_change_requests_path(series)

    expect(response).to redirect_to(root_path)
  end
end
