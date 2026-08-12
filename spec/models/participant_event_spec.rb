require 'rails_helper'

RSpec.describe ParticipantEvent, type: :model do
  describe "ban enforcement" do
    it "is invalid when the participant's email is on an active ban" do
      participant = create(:participant, email: "banned@example.com")
      create(:ban, email: "banned@example.com")

      pe = build(:participant_event, participant: participant)
      expect(pe).not_to be_valid
      expect(pe.errors[:base]).to include("banned@example.com is banned from events")
    end

    it "is valid when the participant's email is not banned" do
      participant = create(:participant, email: "allowed@example.com")
      create(:ban, email: "banned@example.com")

      expect(build(:participant_event, participant: participant, event: create(:event))).to be_valid
    end
  end

  describe ".missing_onboarding_data" do
    def build_pe(event, travel_in: false, travel_out: false, medical: false, dietary: false,
                 accessibility: false, safeguarding: false, consent: false, accommodation: false)
      pe = create(:participant_event, event: event)
      pe.travels.create!(direction: "inbound", mode: "car") if travel_in
      pe.travels.create!(direction: "outbound", mode: "car") if travel_out
      pe.create_medical! if medical
      pe.create_dietary! if dietary
      pe.create_accessibility! if accessibility
      pe.create_safeguarding_info! if safeguarding
      create(:consent, participant_event: pe) if consent
      pe.create_accommodation! if accommodation
      pe
    end

    [ true, false ].each do |accommodation_enabled|
      context "with accommodation_enabled=#{accommodation_enabled}" do
        let(:event) { create(:event, accommodation_enabled: accommodation_enabled) }

        it "matches exactly the records where onboarding_complete? is false" do
          all_on = { travel_in: true, travel_out: true, medical: true, dietary: true,
                     accessibility: true, safeguarding: true, consent: true, accommodation: true }

          pes = [ build_pe(event, **all_on), build_pe(event) ]
          all_on.each_key do |flag|
            pes << build_pe(event, **all_on.merge(flag => false))
          end

          scope_ids = event.participant_events
            .missing_onboarding_data(accommodation_required: event.accommodation_enabled?)
            .pluck(:id).sort
          ruby_ids = pes.reject { |pe| pe.reload.onboarding_complete? }.map(&:id).sort

          expect(scope_ids).to eq(ruby_ids)
        end
      end
    end
  end

  describe "consent predicates" do
    let(:pe) { create(:participant_event) }

    def eager_copy(participant_event)
      ParticipantEvent.includes(:consents).find(participant_event.id)
    end

    describe "#waiver_signed?" do
      it "is true only when a waiver consent is signed" do
        expect(pe.waiver_signed?).to be(false)

        consent = create(:consent, participant_event: pe, status: :sent)
        expect(pe.reload.waiver_signed?).to be(false)

        consent.update!(status: :signed)
        expect(pe.reload.waiver_signed?).to be(true)
      end

      it "ignores signed consents of other types" do
        create(:consent, :freedom_waiver, :signed, participant_event: pe)
        expect(pe.reload.waiver_signed?).to be(false)
      end
    end

    describe "#freedom_waiver_signed?" do
      it "is true only when a freedom_waiver consent is signed" do
        create(:consent, :signed, participant_event: pe)
        expect(pe.reload.freedom_waiver_signed?).to be(false)

        create(:consent, :freedom_waiver, :signed, participant_event: pe)
        expect(pe.reload.freedom_waiver_signed?).to be(true)
      end
    end

    it "returns identical results whether consents are eager-loaded or not" do
      states = [
        {},
        { waiver: :sent },
        { waiver: :signed },
        { waiver: :signed, freedom_waiver: :sent },
        { waiver: :signed, freedom_waiver: :signed }
      ]

      states.each do |state|
        record = create(:participant_event)
        state.each do |type, status|
          create(:consent, participant_event: record, consent_type: type, status: status)
        end

        lazy = ParticipantEvent.find(record.id)
        eager = eager_copy(record)
        expect(eager.consents).to be_loaded

        expect(eager.waiver_signed?).to eq(lazy.waiver_signed?), "waiver_signed? mismatch for #{state.inspect}"
        expect(eager.freedom_waiver_signed?).to eq(lazy.freedom_waiver_signed?), "freedom_waiver_signed? mismatch for #{state.inspect}"
        expect(eager.display_status).to eq(lazy.display_status), "display_status mismatch for #{state.inspect}"
      end
    end

    it "issues no consent queries when consents are eager-loaded" do
      create(:consent, :signed, participant_event: pe)
      create(:consent, :freedom_waiver, participant_event: pe)
      eager = eager_copy(pe)

      consent_queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql].to_s
        consent_queries << sql if sql.start_with?("SELECT") && sql.include?('"consents"')
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        eager.waiver_signed?
        eager.freedom_waiver_signed?
        eager.display_status
      end

      expect(consent_queries).to be_empty
    end

    describe "guardian-blocking via #display_status" do
      let(:event) { create(:event, accommodation_enabled: false, freedom_waivers_enabled: false) }
      let(:minor) { create(:participant, date_of_birth: 15.years.ago) }
      let(:pe) { create(:participant_event, participant: minor, event: event) }

      before do
        create(:guardian_participant_event, participant_event: pe, status: :completed)
        pe.travels.create!(direction: "inbound", mode: "car")
        pe.travels.create!(direction: "outbound", mode: "car")
        pe.create_medical!
        pe.create_dietary!
        pe.create_accessibility!
      end

      it "is Awaiting Parent while the guardian has not signed the blocking waiver" do
        create(:consent, participant_event: pe, status: :sent)

        eager = eager_copy(pe)
        expect(eager.onboarding_progress[:blocking_step]).to eq("waiver")
        expect(eager.display_status).to eq("Awaiting Parent")
        expect(ParticipantEvent.find(pe.id).display_status).to eq("Awaiting Parent")
      end

      it "is Awaiting Participant once the guardian has signed" do
        create(:consent, participant_event: pe, status: :sent, guardian_signed_at: Time.current)

        eager = eager_copy(pe)
        expect(eager.onboarding_progress[:blocking_step]).to eq("waiver")
        expect(eager.display_status).to eq("Awaiting Participant")
        expect(ParticipantEvent.find(pe.id).display_status).to eq("Awaiting Participant")
      end
    end
  end

  describe "#mark_complete_if_eligible!" do
    let(:event) { create(:event) }

    def adult_pe(evt = event)
      create(:participant_event, event: evt, code_of_conduct_accepted_at: Time.current)
        .tap { |pe| pe.participant.update!(date_of_birth: 18.years.ago - 1.month) }
    end

    it "requires a signed waiver" do
      pe = adult_pe

      expect(pe.mark_complete_if_eligible!).to be false
      expect(pe.reload).not_to be_complete

      create(:consent, :signed, participant_event: pe)
      expect(pe.reload.mark_complete_if_eligible!).to be true
      expect(pe.reload).to be_complete
      expect(pe.onboarding_completed_at).to be_present
    end

    it "refuses to complete before the registration is submitted" do
      pe = adult_pe
      pe.update!(code_of_conduct_accepted_at: nil)
      create(:consent, :signed, participant_event: pe)

      expect(pe.mark_complete_if_eligible!).to be false

      pe.update!(code_of_conduct_accepted_at: Time.current)
      expect(pe.mark_complete_if_eligible!).to be true
    end

    it "requires signed custom documents" do
      pe = adult_pe
      create(:consent, :signed, participant_event: pe)
      doc = create(:custom_document, event: event)

      expect(pe.mark_complete_if_eligible!).to be false

      create(:consent, :signed, participant_event: pe, consent_type: :custom_document, custom_document: doc)
      expect(pe.reload.mark_complete_if_eligible!).to be true
    end

    context "for minors" do
      it "requires completed guardians but not a freedom waiver when the event has them disabled" do
        no_freedom_event = create(:event, freedom_waivers_enabled: false)
        pe = create(:participant_event, event: no_freedom_event, code_of_conduct_accepted_at: Time.current)
        create(:consent, :signed, participant_event: pe)

        expect(pe.mark_complete_if_eligible!).to be false

        create(:guardian_participant_event, participant_event: pe, status: :completed, completed_at: Time.current)
        expect(pe.reload.mark_complete_if_eligible!).to be true
      end

      it "requires a signed freedom waiver when the event has them enabled" do
        freedom_event = create(:event, freedom_waivers_enabled: true)
        pe = create(:participant_event, event: freedom_event, code_of_conduct_accepted_at: Time.current)
        create(:consent, :signed, participant_event: pe)
        create(:guardian_participant_event, participant_event: pe, status: :completed, completed_at: Time.current)

        expect(pe.mark_complete_if_eligible!).to be false

        create(:consent, :signed, participant_event: pe, consent_type: :freedom_waiver)
        expect(pe.reload.mark_complete_if_eligible!).to be true
      end
    end
  end

  describe "unaccompanied minor verification" do
    let(:pe) { create(:participant_event) }

    it "defaults to um_none" do
      expect(pe.um_status).to eq("none")
      expect(pe).to be_um_none
    end

    describe "#unaccompanied_minor_declared?" do
      it "is true when a plane travel has the UM flag" do
        pe.travels.create!(direction: "inbound", mode: "plane", is_unaccompanied_minor: true)
        expect(pe.reload.unaccompanied_minor_declared?).to be true
      end

      it "is false when the flag is set on a non-plane travel" do
        pe.travels.create!(direction: "inbound", mode: "car", is_unaccompanied_minor: true)
        expect(pe.reload.unaccompanied_minor_declared?).to be false
      end

      it "is false without the flag" do
        pe.travels.create!(direction: "inbound", mode: "plane")
        expect(pe.reload.unaccompanied_minor_declared?).to be false
      end
    end

    describe "#verified_unaccompanied_minor?" do
      before { pe.travels.create!(direction: "outbound", mode: "plane", is_unaccompanied_minor: true) }

      it "is false while pending" do
        pe.update!(um_status: :pending)
        expect(pe.reload.verified_unaccompanied_minor?).to be false
      end

      it "is true once approved" do
        pe.update!(um_status: :approved)
        expect(pe.reload.verified_unaccompanied_minor?).to be true
      end

      it "is false when approved but no longer declared" do
        pe.update!(um_status: :approved)
        pe.travels.each { |t| t.update!(is_unaccompanied_minor: false) }
        expect(pe.reload.verified_unaccompanied_minor?).to be false
      end
    end

    describe "#approve_um! / #reject_um!" do
      let(:reviewer) { create(:user) }

      it "stamps the reviewer and time on approval" do
        pe.approve_um!(user: reviewer)
        expect(pe).to be_um_approved
        expect(pe.um_verified_by).to eq(reviewer)
        expect(pe.um_verified_at).to be_present
      end

      it "stamps rejection" do
        pe.reject_um!(user: reviewer)
        expect(pe).to be_um_rejected
        expect(pe.um_verified_by).to eq(reviewer)
      end
    end
  end

  describe "#check_in_time" do
    let(:event) { create(:event) }
    let(:pe) { create(:participant_event, event: event) }
    let(:user) { create(:user) }
    let(:check_in) { event.scan_contexts.find_by!(checks_in: true) }
    let(:dinner) { event.scan_contexts.create!(name: "Dinner", checks_in: false) }

    it "is nil with no check-in" do
      expect(pe.check_in_time).to be_nil
    end

    it "returns the earliest check-in scan, ignoring non-check-in contexts" do
      pe.scans.create!(scan_context: dinner, user: user, scanned_at: 5.hours.ago)
      pe.scans.create!(scan_context: check_in, user: user, scanned_at: 1.hour.ago)
      pe.scans.create!(scan_context: check_in, user: user, scanned_at: 3.hours.ago)

      expect(pe.check_in_time).to be_within(1.second).of(3.hours.ago)
    end

    it "goes back to nil when the check-in scans are undone" do
      scan = pe.scans.create!(scan_context: check_in, user: user, scanned_at: 1.hour.ago)
      pe.scans.create!(scan_context: dinner, user: user, scanned_at: 1.hour.ago)
      expect(pe.check_in_time).to be_present

      scan.destroy!

      expect(pe.reload.check_in_time).to be_nil
    end

    # Callers that serialize many registrations (exports, the Airtable sync, the
    # mobile API, MCP tools) all eager-load `scans: :scan_context` and rely on
    # this staying query-free.
    it "works off loaded scans without extra queries" do
      pe.scans.create!(scan_context: dinner, user: user, scanned_at: 5.hours.ago)
      pe.scans.create!(scan_context: check_in, user: user, scanned_at: 1.hour.ago)
      loaded = ParticipantEvent.includes(scans: :scan_context).find(pe.id)

      queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries += 1 unless payload[:name].to_s.in?([ "SCHEMA", "TRANSACTION" ])
      end
      begin
        expect(loaded.check_in_time).to be_within(1.second).of(1.hour.ago)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(queries).to eq(0)
    end
  end
end
