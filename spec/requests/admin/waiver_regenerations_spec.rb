require "rails_helper"

RSpec.describe "Admin waiver regeneration", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:organizer) { User.create!(email: "organizer-waiver-regen@example.com", name: "Organizer") }
  let(:local_organizer) { User.create!(email: "local-waiver-regen@example.com", name: "Local Organizer") }
  let(:event) { create(:event, docuseal_waiver_template_id: "100") }
  let(:flagged_at) { 2.days.ago.change(usec: 0) }
  let(:client) { instance_double(Docuseal::Client) }

  before do
    create(:event_role_assignment, user: organizer, event: event, role: "event_admin")
    create(:event_role_assignment, user: local_organizer, event: event, role: "limited")
    event.update_columns(waiver_dates_stale_since: flagged_at)

    allow(Docuseal::Client).to receive(:for).and_return(client)
    allow(Docuseal::Client).to receive(:new).and_return(client)
    allow(client).to receive(:get_template).with("100")
      .and_return({ "id" => 100, "external_id" => "attend_event_#{event.id}_waiver" })
    allow(client).to receive(:clone_template).and_return({ "id" => 4242 })

    signed = create(:participant_event, event: event)
    create(:consent, participant_event: signed, status: :signed, docuseal_envelope_id: "sub_1")
    unsigned = create(:participant_event, event: event)
    create(:consent, participant_event: unsigned, status: :sent, docuseal_envelope_id: "sub_2")
  end

  describe "GET new" do
    it "shows what will be regenerated and who'll be asked to sign again" do
      sign_in organizer
      get new_admin_event_waiver_regeneration_path(event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Gets a new copy with the new dates")
      expect(response.body).to include("Everyone with a waiver (2 participants)")
      expect(response.body).to include("Only unsigned waivers (1 participant)")
    end

    it "renders in the admin console too" do
      organizer.update!(admin_console_beta: true)
      sign_in organizer
      get new_admin_event_waiver_regeneration_path(event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("cs-tiles")
    end

    it "warns about custom templates it can't change" do
      allow(client).to receive(:get_template).with("100").and_return({ "id" => 100, "external_id" => nil })
      sign_in organizer
      get new_admin_event_waiver_regeneration_path(event)

      expect(response.body).to include("Fix custom templates first")
    end

    it "disables regenerating when DocuSeal can't be reached, in both layouts" do
      allow(client).to receive(:get_template).with("100").and_raise(Docuseal::Error, "unreachable")
      sign_in organizer

      get new_admin_event_waiver_regeneration_path(event)
      expect(response.body).to include("DocuSeal didn&#39;t respond").or include("DocuSeal didn't respond")

      organizer.update!(admin_console_beta: true)
      get new_admin_event_waiver_regeneration_path(event)
      expect(response.body).to include("cs-alert-error")
    end

    it "sends people back once the waivers are up to date" do
      event.update_columns(waiver_dates_stale_since: nil)
      sign_in organizer
      get new_admin_event_waiver_regeneration_path(event)

      expect(response).to redirect_to(admin_event_dashboard_path(event))
    end
  end

  describe "POST create" do
    it "re-clones the template, clears the warning and re-issues everyone's waivers" do
      sign_in organizer

      expect {
        post admin_event_waiver_regeneration_path(event), params: { scope: "everyone" }
      }.to have_enqueued_job(RegenerateWaiversForDateChangeJob).with(event.id, include_signed: true)

      expect(response).to redirect_to(admin_event_dashboard_path(event))
      expect(flash[:notice]).to include("2 participants")
      event.reload
      expect(event.docuseal_waiver_template_id).to eq("4242")
      expect(event).not_to be_waiver_dates_stale
    end

    it "can leave signed waivers alone" do
      sign_in organizer

      expect {
        post admin_event_waiver_regeneration_path(event), params: { scope: "unsigned" }
      }.to have_enqueued_job(RegenerateWaiversForDateChangeJob).with(event.id, include_signed: false)
    end

    it "doesn't run twice when submitted twice" do
      sign_in organizer
      post admin_event_waiver_regeneration_path(event), params: { scope: "everyone" }

      expect {
        post admin_event_waiver_regeneration_path(event), params: { scope: "everyone" }
      }.not_to have_enqueued_job(RegenerateWaiversForDateChangeJob)
      expect(client).to have_received(:clone_template).once
    end

    it "puts the warning back and sends nothing when DocuSeal fails" do
      allow(client).to receive(:clone_template).and_raise(Docuseal::Error, "boom")
      sign_in organizer

      expect {
        post admin_event_waiver_regeneration_path(event), params: { scope: "everyone" }
      }.not_to have_enqueued_job(RegenerateWaiversForDateChangeJob)

      expect(response).to redirect_to(new_admin_event_waiver_regeneration_path(event))
      expect(event.reload.waiver_dates_stale_since).to eq(flagged_at)
    end

    it "puts the warning back when DocuSeal times out" do
      allow(client).to receive(:clone_template).and_raise(Faraday::TimeoutError, "execution expired")
      sign_in organizer

      expect {
        post admin_event_waiver_regeneration_path(event), params: { scope: "everyone" }
      }.not_to have_enqueued_job(RegenerateWaiversForDateChangeJob)

      expect(response).to redirect_to(new_admin_event_waiver_regeneration_path(event))
      expect(flash[:alert]).to include("Nothing was sent")
      expect(event.reload.waiver_dates_stale_since).to eq(flagged_at)
    end

    it "puts the warning back and re-raises on errors it doesn't expect" do
      allow(RegenerateWaiversForDateChangeJob).to receive(:perform_later).and_raise(ActiveRecord::StatementInvalid, "queue down")
      sign_in organizer

      expect {
        post admin_event_waiver_regeneration_path(event), params: { scope: "everyone" }
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(event.reload.waiver_dates_stale_since).to eq(flagged_at)
    end

    [ nil, "everybody" ].each do |scope|
      it "does nothing without a valid choice of who gets a new waiver (#{scope.inspect})" do
        sign_in organizer

        expect {
          post admin_event_waiver_regeneration_path(event), params: { scope: scope }.compact
        }.not_to have_enqueued_job(RegenerateWaiversForDateChangeJob)

        expect(response).to redirect_to(new_admin_event_waiver_regeneration_path(event))
        expect(flash[:alert]).to be_present
        expect(event.reload.waiver_dates_stale_since).to eq(flagged_at)
        expect(client).not_to have_received(:clone_template)
      end
    end

    it "refuses to start when DocuSeal can't say which templates Attend created" do
      allow(client).to receive(:get_template).with("100").and_raise(Docuseal::Error, "unreachable")
      sign_in organizer

      expect {
        post admin_event_waiver_regeneration_path(event), params: { scope: "everyone" }
      }.not_to have_enqueued_job(RegenerateWaiversForDateChangeJob)

      expect(response).to redirect_to(new_admin_event_waiver_regeneration_path(event))
      expect(flash[:alert]).to include("DocuSeal didn't respond")
      expect(event.reload.waiver_dates_stale_since).to eq(flagged_at)
      expect(client).not_to have_received(:clone_template)
    end

    it "is off limits to staff who can't manage templates" do
      sign_in local_organizer

      expect {
        post admin_event_waiver_regeneration_path(event), params: { scope: "everyone" }
      }.not_to have_enqueued_job(RegenerateWaiversForDateChangeJob)

      expect(event.reload).to be_waiver_dates_stale
      expect(client).not_to have_received(:clone_template)
    end
  end
end
