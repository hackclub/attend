require "rails_helper"

# Opening a participant in the admin used to write: it saved the Slack id from
# the participant's account, and minted or restamped every guardian's portal
# link while rendering "Copy Portal Link". The page is now a read. (That a GET
# doesn't write is enforced for every example by spec/support/get_write_detector.rb;
# these cover what staff still see and where the writes went.)
RSpec.describe "Admin participant page is read-only", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:participant) { create(:participant) }
  let!(:participant_event) { create(:participant_event, event: event, participant: participant) }
  let(:admin) { create(:user, global_role: "global_admin") }
  let(:show_path) { admin_event_participant_path(event, participant_event) }

  def page
    Nokogiri::HTML(response.body)
  end

  def copy_button
    page.at_css("button[data-controller='clipboard'][data-clipboard-content-value*='/guardian/portal/']")
  end

  def portal_link_form
    page.at_css("form[action*='guardian_portal_link']")
  end

  { "the console" => true, "the original admin" => false }.each do |ui, console|
    context "in #{ui}" do
      before do
        admin.update!(admin_console_beta: console)
        sign_in admin
        get admin_bans_path # Devise stamps the sign-in on the session's first request
        GetWriteDetector.drain
      end

      describe "a guardian's portal link" do
        let!(:gpe) { create(:guardian_participant_event, participant_event: participant_event) }

        it "is in the copy button as it stands when it is live, with nothing written or queued" do
          token = gpe.generate_invite_token!

          expect { get show_path }.not_to have_enqueued_job

          expect(copy_button["data-clipboard-content-value"]).to end_with("/guardian/portal/#{token}")
          expect(portal_link_form).to be_nil
          expect(GetWriteDetector.drain).to be_empty
        end

        # A lapsed link 404s on arrival. The page never puts one in the copy
        # button: the button is the POST that revives it, so whatever staff
        # end up copying works.
        it "isn't in the copy button once its window has lapsed: the button revives it with a POST" do
          token = gpe.generate_invite_token!
          gpe.update!(invite_token_sent_at: 30.days.ago, invite_last_used_at: nil)

          expect { get show_path }.not_to have_enqueued_job

          expect(copy_button).to be_nil
          expect(response.body).not_to include(token)
          expect(portal_link_form["method"]).to eq("post")
          expect(GetWriteDetector.drain).to be_empty
          expect(gpe.reload.invite_expired?).to be(true)

          post guardian_portal_link_admin_event_participant_path(event, participant_event, guardian_participant_event_id: gpe.id)
          follow_redirect!

          expect(copy_button["data-clipboard-content-value"]).to end_with("/guardian/portal/#{token}")
          expect(GuardianParticipantEvent.find_by_invite_token!(token)).to eq(gpe)
        end

        it "isn't minted by viewing the page: the same button asks for one with a POST" do
          expect(gpe.invite_token).to be_nil

          expect { get show_path }.not_to have_enqueued_job

          expect(gpe.reload.invite_token).to be_nil
          expect(copy_button).to be_nil
          expect(portal_link_form["method"]).to eq("post")
          expect(portal_link_form.at_css("button").text.strip).to match(/\ACopy portal link\z/i)
          expect(GetWriteDetector.drain).to be_empty
        end

        it "is minted and stamped by that POST, after which the page carries it" do
          post guardian_portal_link_admin_event_participant_path(event, participant_event, guardian_participant_event_id: gpe.id)

          expect(response).to redirect_to(show_path)
          token = gpe.reload.invite_token
          expect(token).to be_present
          expect(GuardianParticipantEvent.find_by_invite_token!(token)).to eq(gpe)
          expect(AuditLog.where(action: "guardian_portal_link", actor: admin)).to exist

          follow_redirect!
          expect(copy_button["data-clipboard-content-value"]).to end_with("/guardian/portal/#{token}")
          expect(response.body).to include("is ready to copy")
        end

        it "keeps a link the guardian already has when the POST is repeated" do
          token = gpe.generate_invite_token!

          post guardian_portal_link_admin_event_participant_path(event, participant_event, guardian_participant_event_id: gpe.id)

          expect(gpe.reload.invite_token).to eq(token)
        end

        # The page stops offering the link once the guardian is done. Posting
        # for it anyway must not bring a lapsed link back to life.
        it "isn't offered or revived once the guardian has completed the portal" do
          token = gpe.generate_invite_token!
          gpe.update!(status: :completed, invite_token_sent_at: 30.days.ago, invite_last_used_at: nil)

          get show_path
          expect(copy_button).to be_nil
          expect(portal_link_form).to be_nil

          post guardian_portal_link_admin_event_participant_path(event, participant_event, guardian_participant_event_id: gpe.id)

          expect(response).to redirect_to(show_path)
          expect(flash[:alert]).to include("already completed")
          expect(gpe.reload.invite_expired?).to be(true)
          expect { GuardianParticipantEvent.find_by_invite_token!(token) }.to raise_error(ActiveRecord::RecordNotFound)
        end

        it "isn't offered, or refreshed, while the event has guardian invites locked" do
          gpe.generate_invite_token!
          gpe.update!(invite_token_sent_at: 30.days.ago)
          allow_any_instance_of(Event).to receive(:guardian_invites_locked?).and_return(true)

          get show_path
          expect(copy_button).to be_nil
          expect(portal_link_form).to be_nil

          post guardian_portal_link_admin_event_participant_path(event, participant_event, guardian_participant_event_id: gpe.id)
          expect(flash[:alert]).to include("locked")
          expect(gpe.reload.invite_expired?).to be(true)
        end
      end

      describe "the participant's Slack id" do
        let(:account) { create(:user, oidc_claims: { "slack_id" => "U0EXAMPLE01" }) }

        before { participant.update_columns(user_id: account.id, slack_user_id: nil) }

        it "shows the id from their account straight away and saves it in a job" do
          expect { get show_path }.to have_enqueued_job(SyncParticipantSlackIdJob).with(account)

          expect(response.body).to include("U0EXAMPLE01")
          expect(GetWriteDetector.drain).to be_empty
          expect(participant.reload.slack_user_id).to be_nil

          perform_enqueued_jobs(only: SyncParticipantSlackIdJob)

          expect(participant.reload.slack_user_id).to eq("U0EXAMPLE01")
        end

        it "queues nothing once the two agree" do
          participant.update_columns(slack_user_id: "U0EXAMPLE01")

          expect { get show_path }.not_to have_enqueued_job(SyncParticipantSlackIdJob)
          expect(response.body).to include("U0EXAMPLE01")
        end
      end
    end
  end
end
