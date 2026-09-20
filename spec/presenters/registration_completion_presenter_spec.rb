require "rails_helper"

RSpec.describe RegistrationCompletionPresenter do
  let(:event) { create(:event, freedom_waivers_enabled: false) }
  let(:participant) { create(:participant, date_of_birth: 15.years.ago) }
  let(:participant_event) do
    create(:participant_event, participant: participant, event: event,
      status: :awaiting_guardian, code_of_conduct_accepted_at: Time.current)
  end
  let!(:guardian_participant_event) do
    create(:guardian_participant_event, participant_event: participant_event,
      status: :completed, completed_at: Time.current)
  end

  def presentation(viewer, guardian_participant_event: nil)
    described_class.new(participant_event, viewer: viewer, guardian_participant_event: guardian_participant_event)
  end

  it "assigns the guardian the next action after the attendee signs first" do
    create(:consent, participant_event: participant_event, status: :sent,
      participant_signed_at: Time.current, docuseal_participant_slug: "participant",
      docuseal_guardian_slug: "guardian")

    expect(presentation(:participant).state).to eq(:waiting_on_guardian)
    expect(presentation(:participant)).to be_viewer_tasks_complete
    guardian_presentation = presentation(:guardian, guardian_participant_event: guardian_participant_event)
    expect(guardian_presentation.state).to eq(:action_needed)
    expect(guardian_presentation).not_to be_viewer_tasks_complete
    expect(guardian_presentation.next_task.owner).to eq(:guardian)
  end

  it "assigns the attendee the next action after the guardian signs first" do
    create(:consent, participant_event: participant_event, status: :sent,
      guardian_signed_at: Time.current, docuseal_participant_slug: "participant",
      docuseal_guardian_slug: "guardian")

    expect(presentation(:participant).state).to eq(:action_needed)
    expect(presentation(:participant).next_task.owner).to eq(:participant)
    guardian_presentation = presentation(:guardian, guardian_participant_event: guardian_participant_event)
    expect(guardian_presentation.state).to eq(:waiting_on_participant)
    expect(guardian_presentation).to be_viewer_tasks_complete
  end

  it "reports processing when every signer finished but DocuSeal has not closed the submission" do
    create(:consent, participant_event: participant_event, status: :sent,
      participant_signed_at: Time.current, guardian_signed_at: Time.current,
      docuseal_participant_slug: "participant", docuseal_guardian_slug: "guardian")

    expect(presentation(:participant).state).to eq(:processing)
    expect(presentation(:guardian, guardian_participant_event: guardian_participant_event).state).to eq(:processing)
    expect(presentation(:participant).outstanding_tasks.map(&:owner)).to eq([ :document_processing ])
  end

  it "does not describe a completed guardian profile as all guardian tasks complete while its waiver is unsigned" do
    create(:consent, participant_event: participant_event, status: :sent,
      participant_signed_at: Time.current, docuseal_participant_slug: "participant",
      docuseal_guardian_slug: "guardian")

    guardian_presentation = presentation(:guardian, guardian_participant_event: guardian_participant_event)
    expect(guardian_presentation).not_to be_viewer_tasks_complete
    expect(guardian_presentation.body).to include("sign the event waiver")
  end

  it "distinguishes document preparation from completed-signature processing" do
    create(:consent, participant_event: participant_event, status: :pending,
      guardian_participant_event: guardian_participant_event)

    participant_presentation = presentation(:participant)
    guardian_presentation = presentation(:guardian, guardian_participant_event: guardian_participant_event)

    expect(participant_presentation.state).to eq(:preparing)
    expect(guardian_presentation.state).to eq(:preparing)
    expect(guardian_presentation.headline).to eq("Documents are being prepared")
    expect(guardian_presentation.body).not_to include("signatures")
    expect(participant_presentation.next_task.owner).to eq(:document_preparation)
  end

  it "assigns failed document preparation to staff instead of a signer" do
    create(:consent, participant_event: participant_event, status: :failed,
      guardian_participant_event: guardian_participant_event)

    presenter = presentation(:participant)

    expect(presenter.state).to eq(:staff_attention)
    expect(presenter.next_task.owner).to eq(:staff)
    expect(presenter.body).to include("event team")
    expect(presenter.body).not_to include("processing the signed")
  end

  it "keeps an independently actionable signer task ahead of a failed document" do
    failed_document = create(:custom_document, :dual_signer, event: event, name: "Hotel waiver")
    create(:consent, participant_event: participant_event, consent_type: :custom_document,
      custom_document: failed_document, status: :failed,
      guardian_participant_event: guardian_participant_event)
    create(:consent, participant_event: participant_event, status: :sent,
      guardian_signed_at: Time.current, docuseal_participant_slug: "participant",
      guardian_participant_event: guardian_participant_event)

    presenter = presentation(:participant)

    expect(presenter.state).to eq(:action_needed)
    expect(presenter.next_task.kind).to eq(:waiver)
    expect(presenter.outstanding_tasks).to include(
      an_object_having_attributes(owner: :staff, status: :failed, custom_document: failed_document)
    )
  end

  it "only assigns a guardian the signatures belonging to their concrete link" do
    other_guardian = create(:guardian, legal_first_name: "Morgan", email: "morgan@example.com")
    other_link = create(:guardian_participant_event, guardian: other_guardian,
      participant_event: participant_event, status: :completed, completed_at: Time.current)
    create(:consent, participant_event: participant_event, status: :sent,
      participant_signed_at: Time.current, docuseal_guardian_slug: "guardian",
      guardian_participant_event: other_link)

    current = presentation(:guardian, guardian_participant_event: guardian_participant_event)
    assigned = presentation(:guardian, guardian_participant_event: other_link)

    expect(current).to be_viewer_tasks_complete
    expect(current.state).to eq(:waiting_on_guardian)
    expect(current.body).to include("Morgan")
    expect(assigned).not_to be_viewer_tasks_complete
    expect(assigned.state).to eq(:action_needed)
  end

  it "identifies the specific guardian whose profile remains incomplete" do
    other_guardian = create(:guardian, legal_first_name: "Morgan", email: "morgan@example.com")
    other_link = create(:guardian_participant_event, guardian: other_guardian,
      participant_event: participant_event, status: :pending)
    create(:consent, :signed, participant_event: participant_event)

    current = presentation(:guardian, guardian_participant_event: guardian_participant_event)
    assigned = presentation(:guardian, guardian_participant_event: other_link)

    expect(current).to be_viewer_tasks_complete
    expect(current.state).to eq(:waiting_on_guardian)
    expect(current.body).to include("Morgan")
    expect(assigned.state).to eq(:action_needed)
    expect(assigned.next_task.guardian_participant_event).to eq(other_link)
  end

  it "reports paused documents as waiting on staff without promising an email" do
    event.update!(guardian_invites_locked: true)

    presenter = presentation(:participant)

    expect(presenter.state).to eq(:paused)
    expect(presenter.next_task.owner).to eq(:staff)
    expect(presenter.body).to include("check back")
    expect(presenter.body).not_to include("email you when")
  end

  it "includes required and opted-in optional custom documents but excludes unadded optional activities" do
    required = create(:custom_document, :dual_signer, event: event, name: "Hotel waiver")
    opted_in = create(:custom_document, :optional, event: event, name: "Climbing waiver")
    create(:custom_document, :optional, event: event, name: "Kayaking waiver")
    create(:consent, :signed, participant_event: participant_event)
    create(:consent, participant_event: participant_event, consent_type: :custom_document,
      custom_document: opted_in, opted_in_at: Time.current,
      docuseal_participant_slug: "climber", docuseal_guardian_slug: nil)

    names = presentation(:participant).outstanding_tasks.map(&:name)

    expect(names).to include(required.name, opted_in.name)
    expect(names).not_to include("Kayaking waiver")
  end

  it "uses persisted completion as the confirmed and entry-pass predicate" do
    create(:consent, :signed, participant_event: participant_event)

    pending = presentation(:participant)
    expect(pending).not_to be_confirmed
    expect(pending).not_to be_entry_pass_eligible
    expect(pending.state).to eq(:processing)

    participant_event.update!(status: :complete)
    confirmed = presentation(:participant)
    expect(confirmed).to be_confirmed
    expect(confirmed).to be_entry_pass_eligible
    expect(confirmed.state).to eq(:confirmed)
  end

  it "does not confirm a stale complete row with a newly outstanding document" do
    create(:consent, :signed, participant_event: participant_event)
    participant_event.update!(status: :complete)
    document = create(:custom_document, event: event)
    create(:consent, participant_event: participant_event, consent_type: :custom_document,
      custom_document: document, docuseal_participant_slug: "participant")

    presenter = presentation(:participant)

    expect(presenter).not_to be_confirmed
    expect(presenter).not_to be_entry_pass_eligible
    expect(presenter.state).to eq(:action_needed)
  end
end
