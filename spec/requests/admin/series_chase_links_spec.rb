require "rails_helper"

# The series dashboard's chase links promise a number ("7 haven't named a
# guardian — Tokyo") and then hand the reader a filtered participant list. This
# is the spec that keeps that promise honest: for every stage the dashboard
# counts, the link it renders must return exactly that many people. It used to
# be false three ways — waiver, freedom_waiver and documents had no filter at all
# and landed on the unfiltered list, and profile, accommodation and contacts
# shared `status=awaiting_participant`, so three different numbers pointed at one
# URL that matched none of them.
RSpec.describe "Admin::EventSeries chase links", type: :request do
  include Devise::Test::IntegrationHelpers

  # In the order a participant clears them, so "stalled at stage N" means
  # "everything before N is done" — the rule the dashboard counts by.
  STAGE_ORDER = %i[profile travel accommodation health contacts guardian_portal waiver freedom_waiver documents].freeze

  let(:series) { create(:event_series, name: "Chase", slug: "chase-links-spec") }
  let(:global_admin) do
    User.create!(email: "ga-chase@example.com", name: "Global Admin", global_role: "global_admin")
  end

  # Started, still running, records check-ins: the only shape of event where the
  # arrival stage applies as well as every onboarding stage.
  let!(:event) do
    create(:event, event_series: series, starts_at: 1.day.ago, ends_at: 3.days.from_now,
                   accommodation_enabled: true, freedom_waivers_enabled: true)
  end
  let!(:custom_document) { create(:custom_document, event: event, name: "Hotel Waiver") }

  # Fills in every step before `stage`, leaving that stage as the first uncleared
  # one. `stage: nil` clears the lot.
  def create_stalled_at(stage, surname:, status: :in_progress)
    done = stage.nil? ? STAGE_ORDER : STAGE_ORDER[0...STAGE_ORDER.index(stage)]

    participant = create(
      :participant,
      legal_first_name: "Chase",
      legal_last_name: surname,
      date_of_birth: done.include?(:profile) ? 16.years.ago : nil
    )
    pe = create(:participant_event, event: event, participant: participant, status: status)

    if done.include?(:travel)
      pe.create_travel_inbound!(direction: :inbound)
      pe.create_travel_outbound!(direction: :outbound)
    end
    pe.create_accommodation! if done.include?(:accommodation)
    if done.include?(:health)
      pe.create_medical!
      pe.create_dietary!
      pe.create_accessibility!
    end
    if done.include?(:contacts)
      gpe = create(:guardian_participant_event, participant_event: pe)
      gpe.update!(status: :completed) if done.include?(:guardian_portal)
    end
    create(:consent, :signed, participant_event: pe) if done.include?(:waiver)
    create(:consent, :freedom_waiver, :signed, participant_event: pe) if done.include?(:freedom_waiver)
    if done.include?(:documents)
      create(:consent, :custom_document, :signed, participant_event: pe, custom_document: custom_document)
    end

    pe.reload
  end

  def dashboard
    SeriesDashboard.new(series, events: [ event ], user: global_admin)
  end

  # The count the participant list prints for whatever the filters left behind.
  def listed_count(body)
    body[/(\d+) participants?</, 1].to_i
  end

  describe "every stage's filter" do
    # One person stuck at each stage, one cleared and waiting to be checked in,
    # one already checked in, and a withdrawn participant with an open blocker —
    # so a filter that is merely close, rather than exact, is caught.
    before do
      STAGE_ORDER.each { |stage| create_stalled_at(stage, surname: "Stuck#{stage.to_s.camelize}") }
      create_stalled_at(nil, surname: "StuckArrival")
      create(:participant_event, :checked_in, event: event,
                                              participant: create(:participant, legal_last_name: "AlreadyHere"))
      create_stalled_at(:waiver, surname: "GoneAway", status: :withdrawn)
    end

    it "returns exactly the number of participants the dashboard counted" do
      rows = dashboard.chase_rows
      covered = rows.map { |row| row[:stage].key }

      # If the seed stops exercising a stage, this spec quietly stops testing
      # it — so assert the spread before asserting anything about the filters.
      expect(covered).to include(*STAGE_ORDER, :checked_in)

      rows.each do |row|
        stage = row[:stage]
        expect(stage.filter).to be_present, "#{stage.key} has no filter, so its chase link cannot be honest"

        row[:by_event].each do |entry|
          sign_in global_admin
          get admin_event_participants_path(entry[:event].slug, stage.filter)

          expect(response).to have_http_status(:ok)
          expect(listed_count(response.body)).to eq(entry[:count]),
            "#{stage.key} on #{entry[:event].name}: dashboard said #{entry[:count]}, " \
            "the list returned #{listed_count(response.body)}"
        end
      end
    end

    it "lists the right people, not merely the right number" do
      sign_in global_admin

      get admin_event_participants_path(event.slug, blocked_on: "waiver")

      expect(response.body).to include("StuckWaiver")
      # Every other stage's participant, plus the withdrawn one who is also
      # technically stuck on their waiver, must stay out of this list.
      expect(response.body).not_to include("StuckFreedomWaiver")
      expect(response.body).not_to include("StuckGuardianPortal")
      expect(response.body).not_to include("GoneAway")
    end

    it "keeps people who have not finished onboarding out of the arrival list" do
      sign_in global_admin

      get admin_event_participants_path(event.slug, blocked_on: "checked_in")

      expect(response.body).to include("StuckArrival")
      expect(response.body).not_to include("AlreadyHere")
      expect(response.body).not_to include("StuckProfile")
    end

    it "returns nothing for a stage key it does not recognise" do
      sign_in global_admin

      get admin_event_participants_path(event.slug, blocked_on: "not_a_stage")

      expect(response).to have_http_status(:ok)
      expect(listed_count(response.body)).to eq(0)
    end
  end
end
