require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_have_enqueued_mail, :have_enqueued_mail unless RSpec::Matchers.method_defined?(:not_have_enqueued_mail)

RSpec.describe Docuseal::WaiverDateRegeneration do
  include ActiveJob::TestHelper

  let(:event) do
    create(:event, docuseal_host: "https://new.example.com",
      docuseal_waiver_template_id: "100", docuseal_freedom_waiver_template_id: "200")
  end
  let(:client) { instance_double(Docuseal::Client, archive_submission: true) }

  subject(:regeneration) { described_class.new(event) }

  before do
    allow(Docuseal::Client).to receive(:for).and_return(client)
    allow(Docuseal::Client).to receive(:new).and_return(client)
  end

  def stub_template(id, external_id)
    allow(client).to receive(:get_template).with(id).and_return({ "id" => id.to_i, "external_id" => external_id })
  end

  describe "#templates" do
    it "tells templates Attend cloned apart from custom ones" do
      stub_template("100", "attend_event_#{event.id}_waiver")
      stub_template("200", "organizers-own")

      expect(regeneration.templates.map { |t| [ t.template_type, t.status ] })
        .to eq([ [ "waiver", :default ], [ "freedom_waiver", :custom ] ])
    end

    it "marks a template unknown when the request to DocuSeal times out" do
      allow(client).to receive(:get_template).and_raise(Faraday::TimeoutError, "timeout")

      expect(regeneration.templates.map(&:status)).to all(eq(:unknown))
    end

    it "marks a template unknown when DocuSeal can't be reached" do
      allow(client).to receive(:get_template).and_raise(Docuseal::Error, "timeout")

      expect(regeneration.templates.map(&:status)).to eq([ :unknown, :unknown ])
      expect(regeneration).to be_blocked
    end

    it "isn't blocked when every template could be checked" do
      stub_template("100", "attend_event_#{event.id}_waiver")
      stub_template("200", "organizers-own")

      expect(regeneration).not_to be_blocked
    end

    it "lists the adult waiver template as custom when that's what adults get" do
      event.update!(docuseal_waiver_template_id: nil, docuseal_adult_waiver_template_id: "300")
      stub_template("200", "attend_event_#{event.id}_freedom_waiver")

      adult = regeneration.templates.find { |t| t.template_type == "adult_waiver" }
      expect(adult).to have_attributes(template_id: "300", status: :custom, regenerable?: false, label: "Adult waiver")
      expect(client).not_to have_received(:get_template).with("300")
    end

    it "leaves the adult waiver template out when the event's waiver template is used instead" do
      event.update!(docuseal_adult_waiver_template_id: "300")
      stub_template("100", "attend_event_#{event.id}_waiver")
      stub_template("200", "organizers-own")

      expect(regeneration.templates.map(&:template_type)).to eq(%w[waiver freedom_waiver])
    end
  end

  describe "#regenerate_templates!" do
    before do
      event.update!(docuseal_field_mappings: { "waiver" => { "mappings" => [ { "field_name" => "Custom" } ] } })
      allow(client).to receive(:clone_template).and_return({ "id" => 4242 })
    end

    it "re-clones default templates with the new dates and keeps their mappings" do
      stub_template("100", "attend_event_#{event.id}_waiver")
      stub_template("200", "organizers-own")

      regeneration.regenerate_templates!

      expect(client).to have_received(:clone_template).once.with(
        1, hash_including(values: hash_including(event_dates: event.formatted_date_range.to_s))
      )
      event.reload
      expect(event.docuseal_waiver_template_id).to eq("4242")
      expect(event.docuseal_freedom_waiver_template_id).to eq("200")
      expect(event.docuseal_field_mappings["waiver"]["mappings"]).to eq([ { "field_name" => "Custom" } ])
    end

    it "refuses to go ahead when a template couldn't be checked" do
      stub_template("100", "attend_event_#{event.id}_waiver")
      allow(client).to receive(:get_template).with("200").and_raise(Docuseal::Error, "timeout")

      expect { regeneration.regenerate_templates! }.to raise_error(Docuseal::Error)
      expect(client).not_to have_received(:clone_template)
    end
  end

  describe "#consents_to_reissue" do
    def issued(status:, consent_type: :waiver, participant_event_status: :in_progress)
      pe = create(:participant_event, event: event, status: participant_event_status)
      create(:consent, participant_event: pe, consent_type: consent_type, status: status,
        docuseal_envelope_id: "sub_#{SecureRandom.hex(4)}")
    end

    it "picks issued waivers, optionally including signed ones" do
      unsigned = issued(status: :sent)
      signed = issued(status: :signed)
      freedom = issued(status: :sent, consent_type: :freedom_waiver)
      issued(status: :voided)
      issued(status: :sent, participant_event_status: :withdrawn)
      create(:consent, participant_event: create(:participant_event, event: event), status: :pending)
      create(:consent, participant_event: create(:participant_event), status: :sent, docuseal_envelope_id: "elsewhere")

      expect(regeneration.consents_to_reissue(include_signed: false)).to contain_exactly(unsigned, freedom)
      expect(regeneration.consents_to_reissue(include_signed: true)).to contain_exactly(unsigned, signed, freedom)
      expect(regeneration.people_count(include_signed: true)).to eq(3)
    end
  end

  describe "#reissue!" do
    let(:participant) { create(:participant, date_of_birth: 16.years.ago) }
    let(:participant_event) { create(:participant_event, event: event, participant: participant, status: :complete) }
    let!(:guardian_participant_event) { create(:guardian_participant_event, participant_event: participant_event, status: :completed) }
    let!(:waiver) do
      create(:consent, participant_event: participant_event, status: :signed, docuseal_envelope_id: "sub_old",
        docuseal_participant_slug: "p", docuseal_guardian_slug: "g", docuseal_host: "https://old.example.com",
        signed_at: 1.day.ago, participant_signed_at: 2.days.ago, guardian_signed_at: 1.day.ago,
        document_url: "https://old.example.com/doc.pdf", pending_on: nil, sent_at: 3.days.ago)
    end

    # Issued to the participant alone, the way CreateAdultWaiverJob does it.
    def adult_waiver
      waiver.tap { |consent| consent.update!(docuseal_guardian_slug: nil, guardian_participant_event: nil) }
    end

    it "voids the old submission and puts the waiver back to pending on the event's host" do
      regeneration.reissue!(participant_event, [ waiver ])

      expect(client).to have_received(:archive_submission).with("sub_old")
      waiver.reload
      expect(waiver).to be_pending
      expect(waiver.docuseal_envelope_id).to be_nil
      expect(waiver.docuseal_participant_slug).to be_nil
      expect(waiver.signed_at).to be_nil
      expect(waiver.document_url).to be_nil
      expect(waiver.docuseal_host).to eq("https://new.example.com")
    end

    it "reopens the participant and guardian, then re-issues the waiver" do
      expect {
        regeneration.reissue!(participant_event, [ waiver ])
      }.to have_enqueued_job(DocusealJobs::CreateMinorWaiverJob).with(waiver.id, dates_changed: true)

      expect(participant_event.reload).to be_in_progress
      expect(guardian_participant_event.reload).to be_in_progress
    end

    it "emails the guardian once, leaving the minor's email to their waiver job" do
      freedom = create(:consent, :freedom_waiver, participant_event: participant_event, status: :sent, docuseal_envelope_id: "sub_f")

      expect {
        regeneration.reissue!(participant_event, [ waiver, freedom ])
      }.to have_enqueued_mail(GuardianMailer, :waiver_dates_changed).once
        .and not_have_enqueued_mail(ParticipantMailer, :waiver_dates_changed)
        .and have_enqueued_job(DocusealJobs::CreateFreedomWaiverJob).with(freedom.id)
    end

    it "only emails the guardian when just the freedom waiver is re-issued" do
      freedom = create(:consent, :freedom_waiver, participant_event: participant_event, status: :sent, docuseal_envelope_id: "sub_f")

      expect {
        regeneration.reissue!(participant_event, [ freedom ])
      }.to have_enqueued_mail(GuardianMailer, :waiver_dates_changed)
        .and not_have_enqueued_mail(ParticipantMailer, :waiver_dates_changed)
    end

    it "emails and reopens the guardian the waiver was issued to, not just the first one on file" do
      guardian_participant_event.update!(created_at: 2.days.ago)
      replacement = create(:guardian_participant_event, participant_event: participant_event, status: :completed)
      waiver.update!(guardian_participant_event: replacement)

      expect {
        regeneration.reissue!(participant_event, [ waiver ])
      }.to have_enqueued_mail(GuardianMailer, :waiver_dates_changed)
        .with(guardian_participant_event: replacement, waiver_types: [ :waiver ]).once

      expect(replacement.reload).to be_in_progress
      expect(guardian_participant_event.reload).to be_completed
    end

    it "re-issues an adult's waiver and emails only them" do
      participant.update!(date_of_birth: 30.years.ago)
      guardian_participant_event.destroy!
      consent = adult_waiver

      expect {
        regeneration.reissue!(participant_event.reload, [ consent ])
      }.to have_enqueued_job(DocusealJobs::CreateAdultWaiverJob).with(consent.id)
        .and have_enqueued_mail(ParticipantMailer, :waiver_dates_changed)
        .and not_have_enqueued_mail(GuardianMailer, :waiver_dates_changed)
    end

    it "keeps a guardian-signed waiver on the minor flow even if the new dates make them an adult" do
      participant.update!(date_of_birth: 30.years.ago)
      waiver.update!(guardian_participant_event: guardian_participant_event)

      expect {
        regeneration.reissue!(participant_event.reload, [ waiver ])
      }.to have_enqueued_job(DocusealJobs::CreateMinorWaiverJob).with(waiver.id, dates_changed: true)
        .and have_enqueued_mail(GuardianMailer, :waiver_dates_changed)
        .and not_have_enqueued_mail(ParticipantMailer, :waiver_dates_changed)
      expect(guardian_participant_event.reload).to be_in_progress
    end

    it "keeps an adult-issued waiver on the adult flow even if the new dates make them a minor" do
      consent = adult_waiver

      expect {
        regeneration.reissue!(participant_event, [ consent ])
      }.to have_enqueued_job(DocusealJobs::CreateAdultWaiverJob).with(consent.id)
        .and have_enqueued_mail(ParticipantMailer, :waiver_dates_changed)
        .and not_have_enqueued_mail(GuardianMailer, :waiver_dates_changed)
      expect(guardian_participant_event.reload).to be_completed
    end

    it "skips a guardian-signed waiver when there's no guardian to re-issue it to" do
      guardian_participant_event.destroy!
      freedom = create(:consent, :freedom_waiver, participant_event: participant_event, status: :sent, docuseal_envelope_id: "sub_f")

      expect {
        regeneration.reissue!(participant_event.reload, [ waiver, freedom ])
      }.not_to have_enqueued_job

      expect(client).not_to have_received(:archive_submission)
      expect(waiver.reload).to be_signed
      expect(waiver.docuseal_envelope_id).to eq("sub_old")
      expect(freedom.reload).to be_sent
      expect(participant_event.reload).to be_complete
    end

    it "changes nothing in the db, and sends nothing, if a db update fails partway" do
      freedom = create(:consent, :freedom_waiver, participant_event: participant_event, status: :sent, docuseal_envelope_id: "sub_f")
      allow(participant_event).to receive(:reopen_guardian_portal_access!).and_raise(ActiveRecord::RecordInvalid)

      expect {
        expect { regeneration.reissue!(participant_event, [ waiver, freedom ]) }.to raise_error(ActiveRecord::RecordInvalid)
      }.not_to have_enqueued_job

      expect(waiver.reload).to be_signed
      expect(waiver.docuseal_envelope_id).to eq("sub_old")
      expect(freedom.reload).to be_sent
      expect(participant_event.reload).to be_complete
    end

    it "still re-issues when DocuSeal won't archive the old submission" do
      allow(client).to receive(:archive_submission).and_raise(Docuseal::NotFoundError, "gone")

      regeneration.reissue!(participant_event, [ waiver ])

      expect(waiver.reload).to be_pending
    end
  end
end
