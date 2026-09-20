require "rails_helper"

RSpec.describe "Registration completion states", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, freedom_waivers_enabled: false, name: "Polaris") }
  let(:user) { create(:user) }
  let(:participant) do
    create(:participant, user: user, email: user.email, legal_first_name: "Robin",
      date_of_birth: 15.years.ago)
  end
  let(:participant_event) do
    create(:participant_event, participant: participant, event: event,
      status: :awaiting_guardian, code_of_conduct_accepted_at: Time.current)
  end
  let!(:guardian_participant_event) do
    create(:guardian_participant_event, participant_event: participant_event,
      status: :completed, completed_at: Time.current)
  end
  let(:token) { guardian_participant_event.generate_invite_token! }

  it "gives a guardian an action after the attendee signs first" do
    create(:consent, participant_event: participant_event, status: :sent,
      participant_signed_at: Time.current, docuseal_participant_slug: "participant",
      docuseal_guardian_slug: "guardian")

    get guardian_portal_confirmed_path(token: token)

    expect(response.body).to include("Next: sign the event waiver")
    expect(response.body).to include("Sign the waiver")
    expect(response.body).not_to include("Your tasks are complete")
  end

  it "does not ask a guardian to sign again when they signed first" do
    create(:consent, participant_event: participant_event, status: :sent,
      guardian_signed_at: Time.current, docuseal_participant_slug: "participant",
      docuseal_guardian_slug: "guardian")

    get guardian_portal_confirmed_path(token: token)

    expect(response.body).to include("Your tasks are complete")
    expect(response.body).to include("Robin still needs to sign the event waiver")
    expect(response.body).not_to include("Sign the waiver")
  end

  it "distinguishes signature processing from a missing signature" do
    create(:consent, participant_event: participant_event, status: :sent,
      participant_signed_at: Time.current, guardian_signed_at: Time.current,
      docuseal_participant_slug: "participant", docuseal_guardian_slug: "guardian")

    get guardian_portal_confirmed_path(token: token)

    expect(response.body).to include("Signatures received")
    expect(response.body).to include("processing")
    expect(response.body).not_to include("Sign the waiver")
    expect(response.body).not_to include("still needs to sign")
  end

  it "describes a pending waiver without slugs as preparation rather than received signatures" do
    create(:consent, participant_event: participant_event, status: :pending,
      guardian_participant_event: guardian_participant_event)

    get guardian_portal_confirmed_path(token: token)

    expect(response.body).to include("Documents are being prepared")
    expect(response.body).not_to include("Signatures received")
    expect(response.body).not_to include("Sign the waiver")
  end

  it "links an actionable freedom waiver from the guardian confirmation" do
    event.update!(freedom_waivers_enabled: true)
    create(:consent, :signed, participant_event: participant_event)
    create(:consent, :freedom_waiver, participant_event: participant_event, status: :sent,
      guardian_participant_event: guardian_participant_event, docuseal_guardian_slug: "freedom")

    get guardian_portal_confirmed_path(token: token)

    expect(response.body).to include("Next: sign the Freedom Waiver")
    expect(response.body).to include(guardian_portal_freedom_waiver_path(token: token))
  end

  it "describes the next action without claiming only one task remains" do
    event.update!(freedom_waivers_enabled: true)
    create(:consent, participant_event: participant_event, status: :sent,
      participant_signed_at: Time.current, guardian_participant_event: guardian_participant_event,
      docuseal_guardian_slug: "guardian")
    create(:consent, :freedom_waiver, participant_event: participant_event, status: :sent,
      guardian_participant_event: guardian_participant_event, docuseal_guardian_slug: "freedom")

    get guardian_portal_confirmed_path(token: token)

    expect(response.body).to include("Next: sign the event waiver")
    expect(response.body).not_to include("One thing left")
  end

  it "keeps event details accessible when the attendee must countersign" do
    sign_in user
    create(:consent, participant_event: participant_event, status: :sent,
      guardian_signed_at: Time.current, docuseal_participant_slug: "participant",
      docuseal_guardian_slug: "guardian")

    get dashboard_event_path(participant_event)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Polaris")
    expect(response.body).to include("Sign the event waiver")
  end

  it "shows the published arrival window instead of the contact-us fallback" do
    sign_in user
    event.update!(timezone: "Europe/London",
      arrival_opens_at: "2026-08-01T09:00", arrival_closes_at: "2026-08-01T11:30")

    get dashboard_event_path(participant_event)

    expect(response.body).to include("Arrive between 9:00 AM and 11:30 AM BST on Saturday, August 1.")
    expect(response.body).not_to include("An arrival window has not been published")
  end

  it "shows a paused waiting state without an unusable signing action" do
    sign_in user
    event.update!(guardian_invites_locked: true)

    get dashboard_path

    expect(response.body).to include("Documents paused")
    expect(response.body).to include("check back")
    expect(response.body).not_to include("email you when")
    expect(response.body).not_to include("Countersign waiver")
  end

  it "attributes a failed custom document to event staff on attendee and guardian details" do
    document = create(:custom_document, :dual_signer, event: event, name: "Hotel waiver")
    create(:consent, :signed, participant_event: participant_event)
    create(:consent, participant_event: participant_event, consent_type: :custom_document,
      custom_document: document, status: :failed,
      guardian_participant_event: guardian_participant_event)

    sign_in user
    get dashboard_event_path(participant_event)

    expect(response.body).to include("Staff action needed")
    expect(response.body).not_to include("Waiting on your guardian")
    expect(response.body).not_to include("No action needed")

    get guardian_portal_confirmed_path(token: token)

    expect(response.body).to include("Staff action needed")
    expect(response.body).not_to include("Waiting on Robin")
  end

  it "uses truthful paused copy in attendee and guardian custom-document rows" do
    document = create(:custom_document, :dual_signer, event: event, name: "Hotel waiver")
    create(:consent, :signed, participant_event: participant_event)
    create(:consent, participant_event: participant_event, consent_type: :custom_document,
      custom_document: document, status: :pending,
      guardian_participant_event: guardian_participant_event)
    event.update!(guardian_invites_locked: true)

    sign_in user
    get dashboard_event_path(participant_event)

    expect(response.body).to include("Check back later or contact the event organizers")
    expect(response.body).not_to include("email you when")

    get guardian_portal_confirmed_path(token: token)

    expect(response.body).to include("Check back later or contact the event organizers")
    expect(response.body).not_to include("email you when")
  end

  it "uses the same confirmed predicate for the summary and entry pass" do
    sign_in user
    create(:consent, :signed, participant_event: participant_event)

    get dashboard_path
    expect(response.body).not_to include("Registration confirmed")

    get dashboard_event_path(participant_event)
    expect(response.body).not_to include("ENTRY TICKET")

    participant_event.update!(status: :complete)

    get dashboard_path
    expect(response.body).to include("Registration confirmed")

    get dashboard_event_path(participant_event)
    expect(response.body).to include("Your entry ticket")
  end
end
