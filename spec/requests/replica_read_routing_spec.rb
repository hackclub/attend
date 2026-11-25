require "rails_helper"

# Which database role a request runs on. The reading role here is the test
# database again (see spec/support/reading_role.rb): these examples prove the
# routing and that Rails refuses writes on the reading role, not anything
# about a real standby.
RSpec.describe "Replica read routing", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:role_header) { ReplicaReadRouting::ROLE_HEADER }
  let(:event) { create(:event) }
  let(:admin) { create(:user, global_role: "global_admin") }

  let(:ban_params) do
    { ban: { reason: "Example reason", ban_emails_attributes: { "0" => { email: "banned-example@example.com" } } } }
  end

  def role
    response.headers[role_header]
  end

  def api_headers(user = admin)
    { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" }
  end

  context "with the switch off (the default)" do
    include_context "with a reading role"

    it "never changes role, marks nothing and adds no header" do
      expect(ApplicationRecord).not_to receive(:connected_to)
      sign_in admin

      get admin_bans_path
      expect(response).to have_http_status(:ok)
      expect(role).to be_nil

      post admin_bans_path, params: ban_params
      expect(session[ReplicaReadRouting::SESSION_KEY]).to be_nil

      get api_v1_events_path, headers: api_headers
      expect(response).to have_http_status(:ok)
      expect(role).to be_nil
    end
  end

  context "with the switch on but no replica configured" do
    around do |example|
      ENV[ReplicaReads::FLAG] = "1"
      example.run
    ensure
      ENV.delete(ReplicaReads::FLAG)
    end

    it "behaves exactly as if it were off" do
      expect(ApplicationRecord).not_to receive(:connected_to)
      sign_in admin

      get admin_bans_path

      expect(response).to have_http_status(:ok)
      expect(role).to be_nil
    end
  end

  context "with the switch on" do
    include_context "with a reading role"

    let(:cache) { ActiveSupport::Cache::MemoryStore.new }

    around do |example|
      ENV[ReplicaReads::FLAG] = "1"
      example.run
    ensure
      ENV.delete(ReplicaReads::FLAG)
    end

    before { allow(Rails).to receive(:cache).and_return(cache) }

    describe "the admin" do
      before { sign_in admin }

      it "reads on the replica" do
        expect(ReplicaReads).to receive(:reading).and_call_original

        get admin_bans_path

        expect(response).to have_http_status(:ok)
        expect(role).to eq("reading")
      end

      it "loads the signed-in user before switching, on the primary" do
        get admin_bans_path # the session now holds the user's id

        user_loads = []
        subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          user_loads << User.current_role if payload[:sql].include?('FROM "users"') && !payload[:cached]
        end
        get admin_bans_path
        ActiveSupport::Notifications.unsubscribe(subscription)

        expect(role).to eq("reading")
        expect(user_loads.first).to eq(:writing)
      end

      it "writes on the primary" do
        post admin_bans_path, params: ban_params

        expect(BanEmail.where(email: "banned-example@example.com")).to exist
        expect(role).to eq("writing")
      end

      it "keeps reading from the primary for a few seconds after a write, then goes back to the replica" do
        freeze_time do
          get admin_bans_path
          expect(role).to eq("reading")

          post admin_bans_path, params: ban_params

          get admin_bans_path
          expect(role).to eq("writing")
          expect(response.body).to include("banned-example@example.com")

          travel ReplicaReads.sticky_window - 1.second
          get admin_bans_path
          expect(role).to eq("writing")

          travel 2.seconds
          get admin_bans_path
          expect(role).to eq("reading")
        end
      end

      it "keeps a GET that is known to write on the primary, and treats it as a write" do
        get setup_admin_event_rooming_wizard_path(event)

        expect(role).to eq("writing")

        get admin_bans_path
        expect(role).to eq("writing")
      end

      it "re-runs a GET on the primary when it turns out to write, and reports it", :allow_get_writes do
        allow(ReplicaReads).to receive(:writes_on_get?).and_return(false)
        allow_any_instance_of(Admin::BansController).to receive(:index).and_wrap_original do |original, *args|
          FactoryBot.create(:ban, reason: "Written on a GET")
          original.call(*args)
        end
        expect(Sentry).to receive(:capture_exception).with(instance_of(ActiveRecord::ReadOnlyError), anything)

        get admin_bans_path

        expect(response).to have_http_status(:ok)
        expect(role).to eq("writing")
        expect(Ban.where(reason: "Written on a GET").count).to eq(1)

        # ...and it counts as a write for what comes next.
        allow_any_instance_of(Admin::BansController).to receive(:index).and_call_original
        get admin_bans_path
        expect(role).to eq("writing")
      end

      it "re-runs a GET whose view is what wrote", :allow_get_writes do
        allow(ReplicaReads).to receive(:writes_on_get?).and_return(false)
        create(:ban, email: "viewed-example@example.com")
        allow_any_instance_of(BanEmail).to receive(:email).and_wrap_original do |original|
          original.receiver.touch
          original.call
        end
        allow(Sentry).to receive(:capture_exception)

        get admin_bans_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("viewed-example@example.com")
        expect(role).to eq("writing")
      end

      it "re-runs a GET on the primary when the replica can't be reached, without an error report" do
        allow_any_instance_of(Admin::BansController).to receive(:index).and_wrap_original do |original, *args|
          raise ActiveRecord::ConnectionNotEstablished, "replica is restarting" if ReplicaReads.reading?

          original.call(*args)
        end
        expect(Sentry).not_to receive(:capture_exception)

        get admin_bans_path

        expect(response).to have_http_status(:ok)
        expect(role).to eq("writing")
      end

      it "drops what the replica pass memoized before re-running on the primary", :allow_get_writes do
        allow(ReplicaReads).to receive(:writes_on_get?).and_return(false)
        allow(Sentry).to receive(:capture_exception)
        seen_on_entry = []
        allow_any_instance_of(Admin::BansController).to receive(:index).and_wrap_original do |original, *args|
          controller = original.receiver
          seen_on_entry << controller.instance_variable_defined?(:@memoized_on_replica)
          controller.instance_variable_set(:@memoized_on_replica, true)
          FactoryBot.create(:ban, reason: "Written on a GET")
          original.call(*args)
        end

        get admin_bans_path

        expect(response).to have_http_status(:ok)
        expect(seen_on_entry).to eq([ false, false ])
      end
    end

    describe "the API" do
      it "reads on the replica, with the token looked up on the primary first" do
        roles_at_token_lookup = []
        allow(MobileToken).to receive(:find_by_token).and_wrap_original do |original, token|
          roles_at_token_lookup << MobileToken.current_role
          original.call(token)
        end

        get api_v1_events_path, headers: api_headers

        expect(response).to have_http_status(:ok)
        expect(role).to eq("reading")
        expect(roles_at_token_lookup).to eq([ :writing ])
      end

      it "stamps the token's last use on the primary without leaving the replica for the rest" do
        headers = api_headers
        token = MobileToken.last

        get api_v1_events_path, headers: headers

        expect(role).to eq("reading")
        expect(token.reload.last_used_at).to be_present
      end

      it "keeps one credential on the primary after it writes, and leaves others alone" do
        writer = api_headers
        other = api_headers(create(:user, global_role: "global_admin"))

        freeze_time do
          post api_v1_push_tokens_path, params: { token: "example-device-token", platform: "ios" }, headers: writer
          expect(role).to eq("writing")

          get api_v1_events_path, headers: writer
          expect(role).to eq("writing")

          get api_v1_events_path, headers: other
          expect(role).to eq("reading")

          travel ReplicaReads.sticky_window + 1.second
          get api_v1_events_path, headers: writer
          expect(role).to eq("reading")
        end
      end

      it "never puts the token itself in the cache key" do
        headers = api_headers
        raw_token = headers["Authorization"].delete_prefix("Bearer ")
        keys = []
        allow(cache).to receive(:write).and_wrap_original do |original, key, *args, **options|
          keys << key
          original.call(key, *args, **options)
        end

        post api_v1_push_tokens_path, params: { token: "example-device-token", platform: "ios" }, headers: headers

        expect(keys).not_to be_empty
        expect(keys.join).not_to include(raw_token)
      end

      it "writes nothing to the cache for a token that doesn't authenticate" do
        expect(cache).not_to receive(:write)

        post api_v1_push_tokens_path, params: { token: "example-device-token", platform: "ios" },
          headers: { "Authorization" => "Bearer not-a-real-token" }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    describe "everything else" do
      it "stays on the primary: no role switch for a participant's pages" do
        expect(ReplicaReads).not_to receive(:reading)
        participant_user = create(:user)
        create(:participant, user: participant_user, email: participant_user.email)
        sign_in participant_user

        get dashboard_path

        expect(role).to be_nil
      end

      it "only routes controllers under the admin and API base controllers" do
        Rails.application.eager_load!
        routed = ApplicationController.descendants.select(&:replica_reads_routed) +
          ActionController::API.descendants.select { |controller| controller.try(:replica_reads_routed) }

        expect(routed).not_to be_empty
        expect(routed.reject { |controller| controller <= Admin::BaseController || controller <= Api::V1::BaseController }).to be_empty
        [ OnboardingController, GuardianPortalController, Users::OmniauthCallbacksController, SlackOauthController,
          Training::LessonsController, Api::V1::WebhooksController, Api::V1::SessionsController ].each do |controller|
          expect(controller.try(:replica_reads_routed)).to be_falsey, "#{controller} is routed to the replica"
        end
      end
    end
  end
end
