require "rails_helper"

# Withdrawing is reversible and is day-to-day work for whoever is running the
# event on the ground, so ParticipantEventPolicy#withdraw? admits ops and
# limited alongside event admins -- unlike destroy?, which removes the row.
# These specs pin both halves together: the button the page offers and the
# endpoint behind it, which drifted apart once before.
RSpec.describe "Admin::Participants withdraw authorization", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:participant) { create(:participant, legal_first_name: "Dorothy", legal_last_name: "Vaughan") }
  let!(:participant_event) { create(:participant_event, event: event, participant: participant) }

  def sign_in_with_role(role)
    user = User.create!(email: "#{role}-withdraw@example.com", name: role.titleize)
    EventRoleAssignment.create!(user: user, event: event, role: role)
    sign_in user
    user
  end

  %w[event_admin ops limited].each do |role|
    context "as #{role}" do
      before { sign_in_with_role(role) }

      it "is offered the Withdraw button" do
        get admin_event_participant_path(event.slug, participant_event)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Withdraw")
      end

      it "withdraws the participant" do
        post withdraw_admin_event_participant_path(event.slug, participant_event)

        expect(participant_event.reload.status).to eq("withdrawn")
      end

      it "reinstates a withdrawn participant" do
        participant_event.withdrawn!

        post unwithdraw_admin_event_participant_path(event.slug, participant_event)

        expect(participant_event.reload.status).not_to eq("withdrawn")
      end
    end
  end

  %w[safeguarding_lead read_only].each do |role|
    context "as #{role}" do
      before { sign_in_with_role(role) }

      it "is not offered the Withdraw button" do
        get admin_event_participant_path(event.slug, participant_event)

        if role == "read_only"
          # read_only cannot open the page at all, so there is no button to
          # check for; pin the redirect rather than a body that trivially
          # lacks "Withdraw".
          expect(response).to have_http_status(:redirect)
          expect(flash[:alert]).to include("not authorized")
        else
          expect(response).to have_http_status(:ok)
          expect(response.body).not_to include("Withdraw")
        end
      end

      it "cannot withdraw by posting directly" do
        post withdraw_admin_event_participant_path(event.slug, participant_event)

        expect(participant_event.reload.status).not_to eq("withdrawn")
        expect(flash[:alert]).to include("not authorized")
      end

      it "cannot reinstate by posting directly" do
        participant_event.withdrawn!

        post unwithdraw_admin_event_participant_path(event.slug, participant_event)

        expect(participant_event.reload.status).to eq("withdrawn")
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  # Rejection has no button of its own (it arrives via the API or MCP), so
  # Reinstate is the only way back from it in the UI. Undoing a rejection
  # overrides someone's decision, so it's held to event admins via unreject?.
  describe "rejected registrations" do
    before { participant_event.rejected! }

    let(:reinstate_path) { unwithdraw_admin_event_participant_path(event.slug, participant_event) }
    let(:withdraw_path) { withdraw_admin_event_participant_path(event.slug, participant_event) }

    [ true, false ].each do |console|
      context "in the #{console ? 'console' : 'classic'} admin UI" do
        it "offers event admins Reinstate and no Withdraw" do
          sign_in_with_role("event_admin").update!(admin_console_beta: console)

          get admin_event_participant_path(event.slug, participant_event)

          expect(response).to have_http_status(:ok)
          expect(response.body).to include(reinstate_path)
          expect(response.body).not_to include(withdraw_path)
          expect(response.body).to include("was rejected for this event")
        end

        it "offers ops neither button" do
          sign_in_with_role("ops").update!(admin_console_beta: console)

          get admin_event_participant_path(event.slug, participant_event)

          expect(response).to have_http_status(:ok)
          expect(response.body).not_to include(reinstate_path)
          expect(response.body).not_to include(withdraw_path)
        end
      end
    end

    it "lets an event admin reinstate them" do
      sign_in_with_role("event_admin")

      post reinstate_path

      expect(participant_event.reload.status).to eq("in_progress")
      expect(flash[:notice]).to include("has been reinstated")
    end

    %w[ops limited].each do |role|
      it "does not let #{role} reinstate them by posting directly" do
        sign_in_with_role(role)

        post reinstate_path

        expect(participant_event.reload.status).to eq("rejected")
        expect(flash[:alert]).to include("not authorized")
      end

      # Withdraw-then-reinstate would launder a rejection through the looser
      # withdraw? bar, so withdraw must refuse a rejected registration.
      it "does not let #{role} launder the rejection through withdraw" do
        sign_in_with_role(role)

        post withdraw_path
        expect(participant_event.reload.status).to eq("rejected")
        expect(flash[:alert]).to include("nothing to withdraw")

        post reinstate_path
        expect(participant_event.reload.status).to eq("rejected")
      end
    end
  end

  it "leaves an active registration alone when asked to reinstate it" do
    sign_in_with_role("event_admin")
    participant_event.complete!

    post unwithdraw_admin_event_participant_path(event.slug, participant_event)

    expect(participant_event.reload.status).to eq("complete")
    expect(flash[:alert]).to include("nothing to reinstate")
  end

  # A failed save used to fall through to the exception page, which at the
  # door read as "did that work or not?". It now comes back as an alert.
  describe "when the status change can't be saved" do
    before { sign_in_with_role("event_admin") }

    it "alerts instead of erroring on withdraw" do
      allow_any_instance_of(ParticipantEvent).to receive(:withdrawn!)
        .and_raise(ActiveRecord::RecordInvalid.new(participant_event))

      post withdraw_admin_event_participant_path(event.slug, participant_event)

      expect(response).to redirect_to(admin_event_participant_path(event, participant_event))
      expect(flash[:alert]).to include("Couldn't withdraw")
      expect(flash[:notice]).to be_nil
      expect(participant_event.reload.status).not_to eq("withdrawn")
    end

    it "alerts instead of erroring on reinstate" do
      participant_event.withdrawn!
      allow_any_instance_of(ParticipantEvent).to receive(:in_progress!)
        .and_raise(ActiveRecord::RecordNotSaved.new("Failed to save the record", participant_event))

      post unwithdraw_admin_event_participant_path(event.slug, participant_event)

      expect(response).to redirect_to(admin_event_participant_path(event, participant_event))
      expect(flash[:alert]).to include("Couldn't reinstate")
      expect(participant_event.reload.status).to eq("withdrawn")
    end
  end

  # An ops user on event A must not withdraw someone from event B. The
  # controller scopes the lookup to the current event, so the request 404s
  # before the policy runs; the policy's own Current.event guard is pinned
  # separately so it still holds if that lookup ever widens.
  describe "cross-event access" do
    let(:other_event) { create(:event) }
    let(:other_pe) { create(:participant_event, event: other_event) }

    it "does not let a role holder reach a participant from another event" do
      sign_in_with_role("ops")

      post withdraw_admin_event_participant_path(event.slug, other_pe)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to include("could not be found")
      expect(other_pe.reload.status).not_to eq("withdrawn")
    end

    it "denies withdraw? in the policy when the record is outside Current.event" do
      user = User.create!(email: "ops-cross-event@example.com", name: "Ops")
      EventRoleAssignment.create!(user: user, event: event, role: "ops")

      Current.set(event: event) do
        expect(ParticipantEventPolicy.new(user, participant_event).withdraw?).to be(true)
        expect(ParticipantEventPolicy.new(user, other_pe).withdraw?).to be(false)
      end
    end
  end
end
