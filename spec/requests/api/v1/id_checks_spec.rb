require "rails_helper"

RSpec.describe "Api::V1::IdChecks", type: :request do
  let(:event) { create(:event) }
  let(:admin) { create(:user, global_role: :global_admin) }
  let(:participation) { create(:participant_event, event: event) }
  let(:path) { "/api/v1/events/#{event.id}/participants/#{participation.id}/id_checks" }

  let(:outcome) do
    {
      verdict: "confirmed",
      result: "green",
      document_type: "P",
      issuing_state: "GBR",
      data_integrity: "valid",
      issuer: "valid",
      active_auth: "passed",
      chip_auth: "unsupported",
      access_protocol: "PACE",
      name_match: "exact",
      dob_match: true,
      expired: false
    }
  end

  def headers_for(user)
    { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" }
  end

  def post_check(id_check, headers: headers_for(admin))
    post path, params: { id_check: id_check }, headers: headers, as: :json
  end

  def json
    JSON.parse(response.body)
  end

  it "records one note and one audit log entry for a global admin" do
    expect { post_check(outcome) }
      .to change(Note, :count).by(1)
      .and change(AuditLog.where(action: "id_check"), :count).by(1)

    expect(response).to have_http_status(:created)

    note = Note.find(json["note_id"])
    expect(note.participant_event).to eq(participation)
    expect(note.author).to eq(admin)
    expect(note.body).to eq("ID check confirmed (green): GBR passport. Chip authentic, name exact, DOB match.")

    log = AuditLog.where(action: "id_check").last
    expect(log.record).to eq(participation)
    expect(log.actor).to eq(admin)
    expect(log.event).to eq(event)
    expect(log.metadata).to eq(outcome.stringify_keys.merge("note_id" => note.id))
  end

  it "records a rejection" do
    post_check(outcome.merge(verdict: "rejected", result: "red", issuer: "invalid", document_type: "I"))

    expect(response).to have_http_status(:created)
    expect(Note.find(json["note_id"]).body)
      .to eq("ID check rejected (red): GBR ID card. Chip issuer invalid, name exact, DOB match.")
  end

  it "refuses to confirm a red result" do
    expect { post_check(outcome.merge(result: "red")) }.not_to change(Note, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(AuditLog.where(action: "id_check")).to be_empty
  end

  %w[event_admin safeguarding_lead ops].each do |role|
    it "forbids an event #{role}" do
      staff = create(:user)
      create(:event_role_assignment, user: staff, event: event, role: role)

      expect { post_check(outcome, headers: headers_for(staff)) }.not_to change(Note, :count)

      expect(response).to have_http_status(:forbidden)
      expect(AuditLog.where(action: "id_check")).to be_empty
    end
  end

  it "forbids an event API key" do
    key = EventApiToken.generate_for(event, user: admin, name: "door")

    post_check(outcome, headers: { "Authorization" => "Bearer #{key.token}" })

    expect(response).to have_http_status(:forbidden)
    expect(Note.count).to eq(0)
  end

  it "forbids a series API key" do
    series = create(:event_series)
    event.update!(event_series: series)
    key = SeriesApiToken.generate_for(series, user: admin, name: "door")

    post_check(outcome, headers: { "Authorization" => "Bearer #{key.token}" })

    expect(response).to have_http_status(:forbidden)
    expect(Note.count).to eq(0)
  end

  it "rejects an unknown verdict or result" do
    post_check(outcome.merge(verdict: "maybe"))
    expect(response).to have_http_status(:unprocessable_entity)

    post_check(outcome.merge(result: "blue"))
    expect(response).to have_http_status(:unprocessable_entity)

    expect(Note.count).to eq(0)
    expect(AuditLog.where(action: "id_check")).to be_empty
  end

  it "drops document data that is not on the allowlist" do
    post_check(outcome.merge(document_number: "123456789", surname: "SMITH", photo: "/9j/4AAQ"))

    expect(response).to have_http_status(:created)

    note = Note.find(json["note_id"])
    log = AuditLog.where(action: "id_check").last
    %w[123456789 SMITH /9j/4AAQ].each do |value|
      expect(note.body).not_to include(value)
      expect(log.metadata.to_json).not_to include(value)
    end
    expect(log.metadata.keys).not_to include("document_number", "surname", "photo")
  end
end
