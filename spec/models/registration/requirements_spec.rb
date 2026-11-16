require "rails_helper"

# Tagged fiat_registrations: this is about what the list derives from a
# registration as it stands, so nothing here should re-derive it mid-setup.
RSpec.describe Registration::Requirements, fiat_registrations: true do
  let(:event) { create(:event, travel_enabled: true, accommodation_enabled: false, freedom_waivers_enabled: false) }
  let(:adult) { create(:participant, date_of_birth: 18.years.ago - 1.month) }
  let(:minor) { create(:participant, date_of_birth: 15.years.ago) }

  def requirements(participant_event)
    described_class.new(ParticipantEvent.find(participant_event.id))
  end

  def fill_in_data(pe)
    pe.travels.create!(direction: "inbound", mode: "car")
    pe.travels.create!(direction: "outbound", mode: "car")
    pe.create_medical!
    pe.create_dietary!
    pe.create_accessibility!
  end

  def add_emergency_contact(pe)
    pe.emergency_contacts.create!(name: "Ada Example", phone: "+14155550123")
  end

  def submit(pe)
    pe.update!(code_of_conduct_accepted_at: Time.current)
  end

  describe "an adult's registration" do
    let(:pe) { create(:participant_event, participant: adult, event: event, status: :invited) }

    it "walks from invited to complete" do
      expect(requirements(pe).stage).to eq("invited")
      expect(requirements(pe).blocking.key).to eq("travel")

      pe.update!(status: :in_progress)
      fill_in_data(pe)
      expect(requirements(pe).blocking.key).to eq("code_of_conduct")
      expect(requirements(pe).stage).to eq("in_progress")

      submit(pe)
      expect(requirements(pe).blocking.key).to eq("emergency_contacts")
      add_emergency_contact(pe)
      expect(requirements(pe).blocking.key).to eq("waiver")
      expect(requirements(pe).waiting_on).to eq(:participant)

      create(:consent, :signed, participant_event: pe)
      expect(requirements(pe)).to be_met
      expect(requirements(pe).stage).to eq("complete")
    end

    it "leaves out the steps for modules the event has switched off" do
      keys = requirements(create(:participant_event, participant: adult,
        event: create(:event, travel_enabled: false, accommodation_enabled: false))).all.map(&:key)

      expect(keys).not_to include("travel", "accommodation")
    end
  end

  describe "a minor's registration" do
    let(:pe) { create(:participant_event, participant: minor, event: event) }

    before do
      fill_in_data(pe)
      submit(pe)
    end

    it "waits on the participant for guardian details" do
      expect(requirements(pe).blocking.key).to eq("guardian_details")
      expect(requirements(pe).stage).to eq("in_progress")
    end

    it "waits on the guardian for the portal and their signature" do
      link = create(:guardian_participant_event, participant_event: pe, status: :pending)
      expect(requirements(pe).blocking.key).to eq("guardian_portal")
      expect(requirements(pe).stage).to eq("awaiting_guardian")

      link.update!(status: :completed)
      create(:consent, participant_event: pe, status: :sent)
      expect(requirements(pe).blocking.key).to eq("waiver")
      expect(requirements(pe).stage).to eq("awaiting_guardian")
    end

    it "hands the waiver back to the participant once the guardian has signed" do
      create(:guardian_participant_event, participant_event: pe, status: :completed)
      create(:consent, participant_event: pe, status: :sent, guardian_signed_at: Time.current)

      expect(requirements(pe).waiting_on).to eq(:participant)
      expect(requirements(pe).stage).to eq("in_progress")
    end

    it "is complete once the guardian has finished and the waiver is signed" do
      create(:guardian_participant_event, participant_event: pe, status: :completed)
      create(:consent, :signed, participant_event: pe)

      expect(requirements(pe).stage).to eq("complete")
    end

    it "requires the freedom waiver when the event uses them" do
      event.update!(freedom_waivers_enabled: true)
      create(:guardian_participant_event, participant_event: pe, status: :completed)
      create(:consent, :signed, participant_event: pe)

      expect(requirements(pe).blocking.key).to eq("freedom_waiver")
    end
  end

  describe "#stage for a registration that was complete" do
    let(:pe) { create(:participant_event, participant: adult, event: event, status: :complete) }

    before do
      fill_in_data(pe)
      submit(pe)
      add_emergency_contact(pe)
      create(:consent, :signed, participant_event: pe)
    end

    it "reopens when data goes missing before the event" do
      pe.travels.destroy_all

      expect(requirements(pe).stage).to eq("in_progress")
    end

    it "stays complete when only data goes missing once the event has started" do
      pe.travels.destroy_all
      event.update_columns(starts_at: 1.hour.ago, ends_at: 2.days.from_now)

      expect(requirements(pe).stage).to eq("complete")
    end

    it "still reopens for a missing signature once the event has started" do
      pe.consents.update_all(status: "sent")
      event.update_columns(starts_at: 1.hour.ago, ends_at: 2.days.from_now)

      expect(requirements(pe).stage).to eq("in_progress")
    end

    it "is frozen once the event has ended" do
      pe.consents.update_all(status: "sent")
      event.update_columns(starts_at: 3.days.ago, ends_at: 1.day.ago)

      expect(requirements(pe).stage).to eq("complete")
      expect(requirements(pe).computed_stage).to eq("in_progress")
    end
  end

  describe "#completable?" do
    let(:pe) { create(:participant_event, participant: adult, event: event) }

    it "needs the answers, the submission and the signature" do
      create(:consent, :signed, participant_event: pe)
      submit(pe)
      expect(requirements(pe)).not_to be_completable

      fill_in_data(pe)
      add_emergency_contact(pe)
      expect(requirements(pe)).to be_completable
    end

    it "can answer as if the participant had submitted" do
      fill_in_data(pe)
      add_emergency_contact(pe)
      create(:consent, :signed, participant_event: pe)

      expect(requirements(pe)).not_to be_completable
      expect(requirements(pe).completable?(ignoring_submission: true)).to be(true)
    end

    it "needs every guardian to have finished for a minor" do
      minor_pe = create(:participant_event, participant: minor, event: event, code_of_conduct_accepted_at: Time.current)
      fill_in_data(minor_pe)
      create(:consent, :signed, participant_event: minor_pe)
      expect(requirements(minor_pe)).not_to be_completable

      link = create(:guardian_participant_event, participant_event: minor_pe, status: :in_progress)
      expect(requirements(minor_pe)).not_to be_completable

      link.update_columns(status: "completed")
      expect(requirements(minor_pe)).to be_completable
    end

    it "is never true for a withdrawn registration" do
      fill_in_data(pe)
      add_emergency_contact(pe)
      submit(pe)
      create(:consent, :signed, participant_event: pe)
      pe.update_columns(status: "withdrawn")

      expect(requirements(pe)).not_to be_completable
    end
  end

  it "leaves a complete registration alone for a new document while guardian invites are locked" do
    pe = create(:participant_event, participant: adult, event: event, status: :complete)
    fill_in_data(pe)
    add_emergency_contact(pe)
    submit(pe)
    create(:consent, :signed, participant_event: pe)
    create(:custom_document, event: event)

    expect(requirements(pe).stage).to eq("in_progress")

    event.update!(guardian_invites_locked: true)
    expect(requirements(pe).stage).to eq("complete")
  end

  it "reopens for a document whose signature was discarded, even while guardian invites are locked" do
    pe = create(:participant_event, participant: adult, event: event, status: :complete)
    fill_in_data(pe)
    add_emergency_contact(pe)
    submit(pe)
    create(:consent, :signed, participant_event: pe)
    document = create(:custom_document, event: event)
    event.update!(guardian_invites_locked: true)
    create(:consent, :custom_document, participant_event: pe, custom_document: document, status: :pending)

    expect(requirements(pe).stage).to eq("in_progress")
  end

  describe "staff decisions" do
    %w[withdrawn rejected].each do |status|
      it "keeps a #{status} registration #{status} whatever its progress" do
        pe = create(:participant_event, participant: adult, event: event)
        pe.update_columns(status: status)

        expect(requirements(pe).stage).to eq(status)
        end
    end
  end
end
