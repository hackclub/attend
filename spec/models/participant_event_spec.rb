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

  describe "age limit" do
    let(:event) { create(:event, starts_at: Time.zone.local(2027, 2, 20, 9), ends_at: Time.zone.local(2027, 2, 28, 17)) }

    def registration(date_of_birth)
      build(:participant_event, event: event, participant: create(:participant, date_of_birth: date_of_birth))
    end

    it "is too old when the participant turns 19 by the last day of the event" do
      expect(registration(Date.new(2008, 2, 28))).to be_too_old_for_event
      expect(registration(Date.new(2008, 3, 1))).not_to be_too_old_for_event
    end

    it "isn't too old without a birthday" do
      expect(registration(nil)).not_to be_too_old_for_event
    end

    it "refuses to create a registration for someone too old" do
      pe = registration(Date.new(2000, 1, 1))

      expect(pe).not_to be_valid
      expect(pe.errors[:base]).to include("You will be 19 or older during this event. Please contact event staff for assistance.")
    end

    it "creates it anyway when asked to skip the check" do
      pe = registration(Date.new(2000, 1, 1))
      pe.skip_age_check = true

      expect(pe).to be_valid
    end
  end

  describe "#in_onboarding?" do
    it "is true until the wizard is first submitted" do
      expect(build(:participant_event, status: :invited)).to be_in_onboarding
      expect(build(:participant_event, status: :in_progress, onboarding_completed_at: nil)).to be_in_onboarding
    end

    it "is false once submitted, even if an optional document reopened them" do
      expect(build(:participant_event, status: :in_progress, onboarding_completed_at: 1.day.ago)).not_to be_in_onboarding
      expect(build(:participant_event, status: :complete, onboarding_completed_at: 1.day.ago)).not_to be_in_onboarding
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
      [ true, false ].each do |travel_enabled|
        context "with accommodation_enabled=#{accommodation_enabled}, travel_enabled=#{travel_enabled}" do
          let(:event) { create(:event, accommodation_enabled: accommodation_enabled, travel_enabled: travel_enabled) }

          it "matches exactly the records where onboarding_complete? is false" do
            all_on = { travel_in: true, travel_out: true, medical: true, dietary: true,
                       accessibility: true, safeguarding: true, consent: true, accommodation: true }

            pes = [ build_pe(event, **all_on), build_pe(event) ]
            all_on.each_key do |flag|
              pes << build_pe(event, **all_on.merge(flag => false))
            end

            scope_ids = event.participant_events
              .missing_onboarding_data(accommodation_required: event.accommodation_enabled?,
                                       travel_required: event.travel_enabled?)
              .pluck(:id).sort
            ruby_ids = pes.reject { |pe| pe.reload.onboarding_complete? }.map(&:id).sort

            expect(scope_ids).to eq(ruby_ids)
          end
        end
      end
    end
  end

  describe "#onboarding_progress" do
    # Every optional event module must gate its onboarding step, otherwise
    # participants get stuck on a step that doesn't exist in the wizard.
    { travel_enabled: "travel", accommodation_enabled: "accommodation" }.each do |flag, step|
      it "includes the #{step} step when #{flag} is on" do
        pe = create(:participant_event, event: create(:event, flag => true))
        expect(pe.onboarding_progress[:steps].map { |s| s[:name] }).to include(step)
      end

      it "omits the #{step} step when #{flag} is off" do
        pe = create(:participant_event, event: create(:event, flag => false))
        expect(pe.onboarding_progress[:steps].map { |s| s[:name] }).not_to include(step)
        expect(pe.onboarding_progress[:blocking_step]).not_to eq(step)
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
      # Submitted: the guardian is only in the picture once the participant has
      # accepted the code of conduct, so these scenarios all start past it.
      let(:pe) { create(:participant_event, participant: minor, event: event, code_of_conduct_accepted_at: Time.current) }

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

  describe "#find_or_create_consent!" do
    let(:pe) { create(:participant_event) }

    it "returns the existing consent of that type" do
      existing = create(:consent, :freedom_waiver, participant_event: pe)

      expect(pe.find_or_create_consent!(:freedom_waiver)).to eq(existing)
    end

    it "creates the consent with the block's attributes when none exists" do
      consent = pe.find_or_create_consent!(:freedom_waiver) { |c| c.status = :pending }

      expect(consent).to be_persisted
      expect(consent).to be_freedom_waiver
    end

    it "picks up the other request's row when it loses the insert race" do
      existing = create(:consent, :freedom_waiver, participant_event: pe)
      # Simulate the race: our find missed, so we go straight to the insert.
      allow(pe.consents).to receive(:find_or_create_by!) do |attrs|
        Consent.create!(participant_event: pe, **attrs)
      end

      expect(pe.find_or_create_consent!(:freedom_waiver)).to eq(existing)
      expect(pe.consents.freedom_waiver.count).to eq(1)
    end

    it "is backed by a unique index that still allows several custom documents" do
      create(:consent, :freedom_waiver, participant_event: pe)

      expect { Consent.new(participant_event: pe, consent_type: :freedom_waiver).save!(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
      expect {
        create(:consent, :custom_document, participant_event: pe)
        create(:consent, :custom_document, participant_event: pe)
      }.to change(Consent, :count).by(2)
    end
  end

  describe "#display_status" do
    it "is a label for the stored status" do
      expect(ParticipantEvent.statuses.keys.index_with { |status| build(:participant_event, status: status).display_status }).to eq(
        "invited" => "Awaiting Participant", "in_progress" => "Awaiting Participant",
        "awaiting_guardian" => "Awaiting Parent", "complete" => "Complete",
        "withdrawn" => "Withdrawn", "rejected" => "Rejected"
      )
    end

    it "counts a scope by label in one query" do
      event = create(:event)
      create(:participant_event, event: event, status: :invited)
      create(:participant_event, event: event, status: :in_progress)
      create(:participant_event, event: event, status: :awaiting_guardian)
      create(:participant_event, status: :complete)

      queries = []
      counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
      counts = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        ParticipantEvent.display_status_counts(event.participant_events)
      end

      expect(counts).to eq("Awaiting Participant" => 2, "Awaiting Parent" => 1)
      expect(counts["Complete"]).to eq(0)
      expect(queries.size).to eq(1)
    end
  end

  describe "status following requirements" do
    let(:event) { create(:event) }

    def adult_pe(evt = event, **attributes)
      pe = create(:participant_event, event: evt, code_of_conduct_accepted_at: Time.current,
        participant: create(:participant, date_of_birth: 18.years.ago - 1.month), **attributes)
      fill_in_registration_answers(pe)
    end

    def minor_pe(evt, **attributes)
      pe = create(:participant_event, event: evt, code_of_conduct_accepted_at: Time.current,
        participant: create(:participant, date_of_birth: 15.years.ago), **attributes)
      fill_in_registration_answers(pe)
    end

    it "completes when the waiver is signed, and confirms once" do
      pe = adult_pe

      expect(pe.mark_complete_if_eligible!).to be false
      expect(pe.reload).not_to be_complete

      expect {
        create(:consent, :signed, participant_event: pe)
      }.to have_enqueued_mail(ParticipantMailer, :registration_confirmed)
      expect(pe.reload).to be_complete
      expect(pe.onboarding_completed_at).to be_present
      expect(pe.registration_transitions.chronological.last.cause).to eq("documents_changed")

      expect {
        expect(pe.mark_complete_if_eligible!).to be false
      }.not_to have_enqueued_mail(ParticipantMailer, :registration_confirmed)
    end

    it "waits for the participant's answers" do
      pe = create(:participant_event, event: event, code_of_conduct_accepted_at: Time.current,
        participant: create(:participant, date_of_birth: 18.years.ago - 1.month))
      create(:consent, :signed, participant_event: pe)
      expect(pe.reload).not_to be_complete

      meet_registration_requirements(pe, except: "travel")
      expect(pe.mark_complete_if_eligible!).to be false

      pe.travels.create!(direction: "inbound", mode: "car")
      expect(pe.reload).not_to be_complete
      pe.travels.create!(direction: "outbound", mode: "car")
      expect(pe.reload).to be_complete
    end

    it "reopens when an answer goes missing, and doesn't confirm again when it's back" do
      pe = adult_pe
      create(:consent, :signed, participant_event: pe)
      expect(pe.reload).to be_complete

      pe.travel_inbound.destroy!
      expect(pe.reload).to be_in_progress
      expect(pe.registration_transitions.chronological.last).to have_attributes(cause: "data_changed", blocking_requirement: "travel")

      expect {
        pe.travels.create!(direction: "inbound", mode: "car")
      }.not_to have_enqueued_mail(ParticipantMailer, :registration_confirmed)
      expect(pe.reload).to be_complete
    end

    it "confirms again when a signature had to be redone" do
      pe = adult_pe
      consent = create(:consent, :signed, participant_event: pe)

      consent.update!(status: :sent)
      expect(pe.reload).to be_in_progress

      expect {
        consent.update!(status: :signed)
      }.to have_enqueued_mail(ParticipantMailer, :registration_confirmed)
    end

    # Discarding the signature moves no status while an answer is already
    # missing, so nothing but the first cause is in the history.
    it "confirms again when a signature was discarded while an answer was missing" do
      pe = adult_pe
      consent = create(:consent, :signed, participant_event: pe)
      pe.travel_inbound.destroy!
      expect(pe.reload).to be_in_progress

      consent.update!(status: :sent)
      pe.travels.create!(direction: "inbound", mode: "car")
      expect(pe.reload).to be_in_progress

      expect {
        consent.update!(status: :signed)
      }.to have_enqueued_mail(ParticipantMailer, :registration_confirmed)
      expect(pe.reload).to be_complete
    end

    it "confirms again when a date of birth change brought in a guardian's part" do
      pe = adult_pe
      create(:consent, :signed, participant_event: pe)
      expect(pe.reload).to be_complete

      pe.participant.update!(date_of_birth: 15.years.ago)
      expect(pe.reload).to be_in_progress
      expect(pe.registration_transitions.chronological.last.cause).to eq("data_changed")

      meet_registration_requirements(pe)
      expect {
        pe.sync_status!(cause: :guardian_completed)
      }.to have_enqueued_mail(ParticipantMailer, :registration_confirmed)
      expect(pe.reload).to be_complete
    end

    it "leaves a complete registration alone for missing answers once the event has started" do
      pe = adult_pe
      create(:consent, :signed, participant_event: pe)
      event.update_columns(starts_at: 1.hour.ago, ends_at: 2.days.from_now)

      pe.travel_inbound.destroy!

      expect(pe.reload).to be_complete
    end

    it "never moves a withdrawn or rejected registration" do
      pe = adult_pe
      pe.set_by_staff!(:withdrawn)
      create(:consent, :signed, participant_event: pe)
      expect(pe.reload).to be_withdrawn

      pe.set_by_staff!(:rejected)
      expect(pe.mark_complete_if_eligible!).to be false
      expect(pe.reload).to be_rejected
    end

    it "lands a reinstated registration wherever its requirements put it" do
      pe = adult_pe
      create(:consent, :signed, participant_event: pe)
      pe.set_by_staff!(:withdrawn)

      pe.set_by_staff!(:in_progress)

      expect(pe.reload).to be_complete
      expect(pe.registration_transitions.chronological.last(2).map(&:cause)).to eq(%w[reinstated reinstated])
    end

    it "refuses any other status set by hand" do
      expect { adult_pe.set_by_staff!(:complete) }.to raise_error(ArgumentError, /can't be set by hand/)
    end

    it "doesn't complete before the registration is submitted" do
      pe = adult_pe(event, code_of_conduct_accepted_at: nil)
      create(:consent, :signed, participant_event: pe)
      expect(pe.reload).not_to be_complete

      pe.update!(code_of_conduct_accepted_at: Time.current)
      expect(pe.mark_complete_if_eligible!(cause: :submitted)).to be true
    end

    # Signatures (and a guardian's whole part) can all land before the
    # participant submits, and nothing else would prompt them to come back.
    it "emails the participant once when submitting is the only thing left" do
      pe = adult_pe(event, code_of_conduct_accepted_at: nil)

      expect {
        expect(pe.mark_complete_if_eligible!).to be false
      }.not_to have_enqueued_mail(ParticipantMailer, :submission_needed)

      expect {
        create(:consent, :signed, participant_event: pe)
      }.to have_enqueued_mail(ParticipantMailer, :submission_needed)
      expect(pe.reload.submission_reminder_sent_at).to be_present

      expect {
        pe.mark_complete_if_eligible!
      }.not_to have_enqueued_mail(ParticipantMailer, :submission_needed)
    end

    it "doesn't send the submit reminder once the participant has submitted" do
      pe = adult_pe

      expect {
        create(:consent, :signed, participant_event: pe)
      }.not_to have_enqueued_mail(ParticipantMailer, :submission_needed)
      expect(pe.reload.submission_reminder_sent_at).to be_nil
    end

    it "sends the submit reminder for a minor once their guardian has finished" do
      pe = minor_pe(create(:event, freedom_waivers_enabled: false), code_of_conduct_accepted_at: nil)
      gpe = create(:guardian_participant_event, participant_event: pe, status: :pending)

      expect {
        create(:consent, :signed, participant_event: pe)
      }.not_to have_enqueued_mail(ParticipantMailer, :submission_needed)

      expect {
        gpe.update!(status: :completed, completed_at: Time.current)
      }.to have_enqueued_mail(ParticipantMailer, :submission_needed)
      expect(pe.reload).to be_in_progress
    end

    it "requires signed custom documents" do
      pe = adult_pe
      doc = create(:custom_document, event: event)
      create(:consent, :signed, participant_event: pe)
      expect(pe.reload).not_to be_complete

      create(:consent, :signed, participant_event: pe, consent_type: :custom_document, custom_document: doc)
      expect(pe.reload).to be_complete
    end

    context "for minors" do
      let(:no_freedom_event) { create(:event, freedom_waivers_enabled: false) }

      it "waits on the guardian, then completes when they finish" do
        pe = minor_pe(no_freedom_event)
        create(:consent, :signed, participant_event: pe)
        expect(pe.reload).to be_in_progress

        gpe = create(:guardian_participant_event, participant_event: pe, status: :in_progress)
        expect(pe.reload).to be_awaiting_guardian

        # Load the association so it holds a stale copy of the guardian, which
        # is exactly the state GuardianPortalController#complete used to be in.
        pe.guardian_participant_events.load
        gpe.update!(status: :completed, completed_at: Time.current)

        expect(pe.reload).to be_complete
      end

      it "does not complete the participant when another guardian is still pending" do
        pe = minor_pe(no_freedom_event)
        create(:consent, :signed, participant_event: pe)
        first = create(:guardian_participant_event, participant_event: pe, status: :in_progress)
        create(:guardian_participant_event, participant_event: pe, status: :in_progress)

        first.update!(status: :completed, completed_at: Time.current)

        expect(pe.reload).to be_awaiting_guardian
      end

      it "hands the waiver back to the participant once the guardian has signed it" do
        pe = minor_pe(no_freedom_event)
        create(:guardian_participant_event, participant_event: pe, status: :completed, completed_at: Time.current)
        consent = create(:consent, participant_event: pe, status: :sent)
        expect(pe.reload).to be_awaiting_guardian

        consent.update!(guardian_signed_at: Time.current)
        expect(pe.reload).to be_in_progress
      end

      it "requires a signed freedom waiver when the event has them enabled" do
        pe = minor_pe(create(:event, freedom_waivers_enabled: true))
        create(:consent, :signed, participant_event: pe)
        create(:guardian_participant_event, participant_event: pe, status: :completed, completed_at: Time.current)
        expect(pe.reload).not_to be_complete

        create(:consent, :signed, participant_event: pe, consent_type: :freedom_waiver)
        expect(pe.reload).to be_complete
      end
    end

    # What the ticket API goes by. Rows from before statuses were derived,
    # or one whose sync was missed, hold a status the requirements don't back.
    describe "#confirmed?" do
      it "is false for a stale complete" do
        pe = adult_pe
        pe.update_columns(status: "complete")

        expect(pe).not_to be_confirmed
      end

      it "is true for a registration that has everything, whatever is stored" do
        pe = meet_registration_requirements(adult_pe)
        expect(pe).to be_in_progress

        expect(pe).to be_confirmed
      end

      it "is false for a withdrawn registration that has everything" do
        pe = meet_registration_requirements(adult_pe)
        pe.set_by_staff!(:withdrawn)

        expect(pe).not_to be_confirmed
      end

      it "keeps a ticket through answers going missing once the event has started" do
        pe = adult_pe
        create(:consent, :signed, participant_event: pe)
        event.update_columns(starts_at: 1.hour.ago, ends_at: 2.days.from_now)
        pe.travel_inbound.destroy!

        expect(pe.reload).to be_confirmed
      end
    end

    it "re-derives every registration when the event switches a module on" do
      event.update!(travel_enabled: false)
      pe = adult_pe
      create(:consent, :signed, participant_event: pe)
      expect(pe.reload).to be_complete

      expect {
        perform_enqueued_jobs(only: ResyncRegistrationsJob) { event.update!(travel_enabled: true) }
      }.to have_enqueued_mail(ParticipantMailer, :information_needed).once

      expect(pe.reload).to be_in_progress
      expect(pe.registration_transitions.chronological.last.cause).to eq("settings_changed")
    end

    # Everything else on the event that the requirements read.
    describe "event changes that re-derive its registrations" do
      it "includes the timezone, which can move the start date and with it who is a minor" do
        expect { event.update!(timezone: "Pacific/Auckland") }
          .to have_enqueued_job(ResyncRegistrationsJob).with(event.id)
      end

      it "includes an end moved back into the future, which thaws an ended event" do
        event.update_columns(starts_at: 5.days.ago, ends_at: 1.day.ago)
        pe = adult_pe
        pe.update_columns(status: "complete")

        expect {
          perform_enqueued_jobs(only: ResyncRegistrationsJob) { event.update!(ends_at: 2.days.from_now) }
        }.to change { pe.reload.status }.from("complete").to("in_progress")
      end

      it "leaves out an end that only moves later" do
        expect { event.update!(ends_at: event.ends_at + 1.day) }
          .not_to have_enqueued_job(ResyncRegistrationsJob)
      end
    end

    it "doesn't email anyone the change leaves where they were" do
      event.update!(travel_enabled: false)
      unfinished = adult_pe
      expect(unfinished.reload).to be_in_progress

      expect {
        perform_enqueued_jobs(only: ResyncRegistrationsJob) { event.update!(travel_enabled: true) }
      }.not_to have_enqueued_mail(ParticipantMailer, :information_needed)
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
      earliest = 3.hours.ago.change(usec: 0)
      pe.scans.create!(scan_context: dinner, user: user, scanned_at: 5.hours.ago)
      pe.scans.create!(scan_context: check_in, user: user, scanned_at: 1.hour.ago)
      pe.scans.create!(scan_context: check_in, user: user, scanned_at: earliest)

      expect(pe.check_in_time).to eq(earliest)
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
      checked_in_at = 1.hour.ago.change(usec: 0)
      pe.scans.create!(scan_context: dinner, user: user, scanned_at: 5.hours.ago)
      pe.scans.create!(scan_context: check_in, user: user, scanned_at: checked_in_at)
      loaded = ParticipantEvent.includes(scans: :scan_context).find(pe.id)

      queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries += 1 unless payload[:name].to_s.in?([ "SCHEMA", "TRANSACTION" ])
      end
      begin
        expect(loaded.check_in_time).to eq(checked_in_at)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(queries).to eq(0)
    end
  end
  describe "#revoke_invitations!" do
    let(:event) { create(:event) }

    it "destroys the event's invitation for that email, closing the re-entry route" do
      participant = create(:participant, email: "leaving@example.com")
      invitation = create(:invitation, event: event, email: "leaving@example.com", sent_at: Time.current)
      pe = create(:participant_event, participant: participant, event: event)

      expect { pe.revoke_invitations! }.to change(Invitation, :count).by(-1)
      expect(Invitation.exists?(invitation.id)).to be(false)
    end

    it "matches the invitation across email casing" do
      participant = create(:participant, email: "Mixed@Example.com")
      create(:invitation, event: event, email: "mixed@example.com", sent_at: Time.current)
      pe = create(:participant_event, participant: participant, event: event)

      expect { pe.revoke_invitations! }.to change(Invitation, :count).by(-1)
    end

    it "leaves the same person's invitation to another event alone" do
      participant = create(:participant, email: "two@example.com")
      other_event = create(:event)
      keep = create(:invitation, event: other_event, email: "two@example.com", sent_at: Time.current)
      create(:invitation, event: event, email: "two@example.com", sent_at: Time.current)
      pe = create(:participant_event, participant: participant, event: event)

      pe.revoke_invitations!

      expect(Invitation.exists?(keep.id)).to be(true)
    end

    it "leaves other people's invitations to this event alone" do
      participant = create(:participant, email: "mine@example.com")
      keep = create(:invitation, event: event, email: "someone-else@example.com", sent_at: Time.current)
      create(:invitation, event: event, email: "mine@example.com", sent_at: Time.current)
      pe = create(:participant_event, participant: participant, event: event)

      pe.revoke_invitations!

      expect(Invitation.exists?(keep.id)).to be(true)
    end

    it "is not fired by a merge, which destroys a registration without uninviting anyone" do
      primary = create(:participant, email: "primary@example.com")
      duplicate = create(:participant, email: "duplicate@example.com")
      create(:invitation, event: event, email: "primary@example.com", sent_at: Time.current)
      create(:participant_event, participant: primary, event: event, status: :invited)
      create(:participant_event, participant: duplicate, event: event, status: :complete)

      expect {
        ParticipantMergeService.new(primary: primary, duplicate: duplicate).merge!
      }.not_to change(Invitation, :count)
    end
  end

  describe "accepting invitations once registration starts" do
    let(:event) { create(:event) }
    let(:participant) { create(:participant, email: "Juniper.Vale@example.com") }

    it "accepts the invitation when someone starts from their dashboard instead of the link" do
      invitation = create(:invitation, event: event, email: "juniper.vale@example.com", sent_at: Time.current)

      create(:participant_event, participant: participant, event: event, status: :in_progress)

      expect(invitation.reload).to be_accepted
    end

    it "accepts it when an imported registration moves off invited" do
      invitation = create(:invitation, event: event, email: "juniper.vale@example.com", sent_at: Time.current)
      pe = create(:participant_event, participant: participant, event: event, status: :invited)
      expect(invitation.reload).not_to be_accepted

      pe.update!(status: :in_progress)

      expect(invitation.reload).to be_accepted
    end

    it "leaves an invited registration's invitation pending, and other events' invitations alone" do
      held = create(:invitation, event: event, email: "juniper.vale@example.com", sent_at: nil)
      elsewhere = create(:invitation, event: create(:event), email: "juniper.vale@example.com", sent_at: Time.current)

      create(:participant_event, participant: participant, event: event, status: :invited)

      expect(held.reload).not_to be_accepted
      expect(elsewhere.reload).not_to be_accepted
    end
  end

  describe "Slack channel invite on completion" do
    include ActiveJob::TestHelper

    it "enqueues an invite when a registration in an event with a channel becomes complete" do
      pe = create(:participant_event, event: create(:event, slack_channel_id: "C123"))

      expect { pe.update!(status: :complete) }
        .to have_enqueued_job(InviteToEventSlackChannelJob).with(pe.id)
    end
  end

  # .onboarding_held_in is the SQL form of #onboarding_held?; the participant
  # list filters with one and the dashboard counts with the other.
  describe ".onboarding_held_in" do
    let(:event) { create(:event, onboarding_invites_held: true) }

    it "selects exactly the registrations #onboarding_held? is true for" do
      no_row = create(:participant_event, event: event, status: :invited)
      emailed = create(:participant_event, event: event, status: :invited)
      create(:invitation, event: event, email: emailed.participant.email.upcase, sent_at: 1.day.ago)
      held_row = create(:participant_event, event: event, status: :invited)
      create(:invitation, event: event, email: held_row.participant.email, sent_at: nil)
      create(:participant_event, event: event, status: :in_progress)

      sent = Invitation.sent_emails_by_event([ event ]).fetch(event.id, Set.new)
      in_ruby = event.participant_events.select { |pe| pe.onboarding_held? }
      batched = event.participant_events.select { |pe| pe.onboarding_held?(sent_emails: sent) }

      expect(described_class.onboarding_held_in(event)).to match_array(in_ruby)
      expect(batched).to match_array(in_ruby)
      expect(in_ruby).to contain_exactly(no_row, held_row)
    end

    it "is empty when the event is not holding invitations" do
      event.update!(onboarding_invites_held: false)
      create(:participant_event, event: event, status: :invited)

      expect(described_class.onboarding_held_in(event)).to be_empty
    end
  end
end
