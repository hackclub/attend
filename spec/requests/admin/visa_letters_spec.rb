require "rails_helper"

RSpec.describe "Admin visa letters", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, name: "Fictional Hackathon", visa_letters: "open", visa_letter_rejection_reasons: [ "The name doesn't match your passport." ]) }
  let(:admin) { create(:user, email: "visa-admin@example.com", admin_console_beta: false).tap { |user| create(:event_role_assignment, user: user, event: event, role: "event_admin") } }
  let(:application) { create(:visa_letter_application, event: event, full_name: "Ada Example") }

  before do
    create(:visa_letter_template, :default)
    sign_in admin
  end

  { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
    context ui do
      before { admin.update!(admin_console_beta: console) }

      it "lists applications awaiting review, and finds one by reference number" do
        application
        letter_sent = create(:visa_letter_application, event: event, full_name: "Grace Sample", status: :letter_sent)

        get admin_event_visa_letters_path(event)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Ada Example")
        expect(response.body).not_to include("Grace Sample")

        get admin_event_visa_letters_path(event, status: "all", q: letter_sent.reference_number.downcase)

        expect(response.body).to include("Grace Sample")
        expect(response.body).not_to include("Ada Example")
      end

      it "shows an application and records that it was opened" do
        expect {
          get admin_event_visa_letter_path(event, application)
        }.to change { AuditLog.where(action: "view", record_id: application.id).count }.by(1)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Exampleland")
        expect(response.body).to include("Approve and send letter")
        expect(response.body).to include("The name doesn&#39;t match your passport.")
      end

      it "approves, and queues the letter" do
        expect {
          post approve_admin_event_visa_letter_path(event, application)
        }.to have_enqueued_job(GenerateVisaLetterJob).with(application)

        expect(application.reload).to be_approved
        expect(application.reviewed_by).to eq(admin)
        expect(AuditLog.where(action: "approve_letter", record_id: application.id)).to exist
      end

      it "rejects with a saved reason and emails the applicant" do
        expect {
          post reject_admin_event_visa_letter_path(event, application),
            params: { rejection_reason_preset: "The name doesn't match your passport.", rejection_type: "hard" }
        }.to have_enqueued_mail(VisaLetterMailer, :rejected)

        expect(application.reload).to be_hard_rejected
        expect(application.rejection_reason).to eq("The name doesn't match your passport.")
      end

      it "won't reject without a reason" do
        post reject_admin_event_visa_letter_path(event, application), params: { rejection_reason: "" }

        expect(application.reload).to be_pending
        expect(flash[:alert]).to eq("Give a reason for the rejection.")
      end

      it "softens a hard rejection" do
        application.reject!(by: admin, reason: "Duplicate", type: :hard)

        post downgrade_rejection_admin_event_visa_letter_path(event, application)

        expect(application.reload).to be_soft_rejected
      end

      context "once the letter is sent" do
        before do
          application.approve!(by: admin)
          application.issue_letter!
        end

        it "downloads it, resends it and records the visa outcome" do
          get letter_admin_event_visa_letter_path(event, application)
          expect(response.media_type).to eq("application/pdf")
          expect(response.body).to start_with("%PDF")

          expect {
            post resend_admin_event_visa_letter_path(event, application)
          }.to have_enqueued_mail(VisaLetterMailer, :letter_ready)

          post record_visa_outcome_admin_event_visa_letter_path(event, application), params: { visa_outcome: "granted" }
          expect(application.reload).to be_visa_granted

          get admin_event_visa_letter_path(event, application)
          expect(response.body).to include("Visa outcome")
          expect(response.body).to include(application.verification_code)
        end
      end

      it "saves the team's notes" do
        patch admin_event_visa_letter_path(event, application), params: { visa_letter_application: { admin_notes: "Called to confirm" } }

        expect(application.reload.admin_notes).to eq("Called to confirm")
      end

      it "saves the event's visa letter settings" do
        get edit_admin_event_visa_letter_settings_path(event)
        expect(response).to have_http_status(:ok)

        patch admin_event_visa_letter_settings_path(event), params: { event: {
          visa_letters: "invite_only", visa_letter_deadline: "2027-01-31",
          visa_letter_rejection_reasons: "Missing passport name\n\nWrong event\nMissing passport name"
        } }

        event.reload
        expect(event.visa_letters_mode).to eq("invite_only")
        expect(event.visa_letter_deadline_date).to eq(Date.new(2027, 1, 31))
        expect(event.visa_letter_rejection_reasons_list).to eq([ "Missing passport name", "Wrong event" ])
      end

      it "shows the module in the sidebar" do
        get admin_event_visa_letters_path(event)

        expect(response.body).to include(admin_event_visa_letters_path(event))
      end
    end
  end

  it "keeps staff who aren't event admins out" do
    %w[ops limited safeguarding_lead read_only].each do |role|
      staff = create(:user).tap { |user| create(:event_role_assignment, user: user, event: event, role: role) }
      sign_in staff

      get admin_event_visa_letter_path(event, application)
      expect(response).to redirect_to(root_path), "#{role} could open an application"

      post approve_admin_event_visa_letter_path(event, application)
      expect(application.reload).to be_pending
    end
  end

  it "only lets event admins choose who can apply, from the event form and setup wizard too" do
    event.update!(visa_letters: "off")
    ops = create(:user).tap { |user| create(:event_role_assignment, user: user, event: event, role: "ops") }
    sign_in ops

    patch admin_event_path(event), params: { event: { visa_letters: "open", name: "Renamed by ops" } }
    patch admin_event_setup_modules_path(event), params: { event: { visa_letters: "open", groups_enabled: "1" } }
    event.reload
    expect(event.name).to eq("Renamed by ops")
    expect(event.groups_enabled).to eq("1")
    expect(event.visa_letters_mode).to eq("off")

    sign_in admin
    patch admin_event_setup_modules_path(event), params: { event: { visa_letters: "open" } }
    expect(event.reload.visa_letters_mode).to eq("open")
  end
end
