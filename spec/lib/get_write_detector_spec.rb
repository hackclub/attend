require "rails_helper"

# The suite-wide check lives in spec/support/get_write_detector.rb: any example
# whose GET writes outside config/get_write_allowlist.yml fails. These examples
# cover the detector itself, and drain what they record so that check doesn't
# fire on them.
RSpec.describe GetWriteDetector do
  def rack_request(method, path = "/detector-example", &work)
    app = lambda do |_env|
      work.call
      [ 200, {}, [ "ok" ] ]
    end
    described_class::Middleware.new(app).call(Rack::MockRequest.env_for(path, method: method))
    described_class.drain
  end

  let!(:user) { create(:user) }

  describe "recording" do
    it "records a write made while serving a GET, with what was hit and where" do
      writes = rack_request("GET") { User.where(id: user.id).update_all(name: "Example Name") }

      expect(writes.sole).to have_attributes(
        http_method: "GET", path: "/detector-example", endpoint: "(rack) /detector-example", table: "users"
      )
      expect(writes.sole.sql).to start_with('UPDATE "users"')
    end

    it "records HEAD requests too" do
      expect(rack_request("HEAD") { user.update!(name: "Example Name") }.map(&:table)).to include("users")
    end

    it "ignores reads" do
      expect(rack_request("GET") { User.find(user.id) }).to be_empty
    end

    it "counts a row lock, which a standby refuses just like a write" do
      writes = rack_request("GET") { user.with_lock { nil } }

      expect(writes.map(&:table)).to eq([ "users" ])
      expect(writes.sole.sql).to include("FOR UPDATE")
    end

    it "leaves POSTs alone" do
      expect(rack_request("POST") { user.update!(name: "Example Name") }).to be_empty
    end

    describe "jobs" do
      include ActiveJob::TestHelper

      before do
        stub_const("DetectorExampleJob", Class.new(ApplicationJob) do
          def perform(user)
            user.update!(name: "Written By A Job")
          end
        end)
      end

      it "doesn't count what a queued job wrote when a test runs it inline: in production that is a worker's write" do
        writes = rack_request("GET") { perform_enqueued_jobs { DetectorExampleJob.perform_later(user) } }

        expect(user.reload.name).to eq("Written By A Job")
        expect(writes).to be_empty
      end

      it "counts what perform_now wrote: that runs inside the request in production too" do
        writes = rack_request("GET") { DetectorExampleJob.perform_now(user) }

        expect(user.reload.name).to eq("Written By A Job")
        expect(writes.map(&:table)).to include("users")
      end

      it "counts what a job wrote on the inline adapter, which also runs it inside the request" do
        DetectorExampleJob.queue_adapter = :inline

        writes = rack_request("GET") { DetectorExampleJob.perform_later(user) }

        expect(user.reload.name).to eq("Written By A Job")
        expect(writes.map(&:table)).to include("users")
      end
    end

    it "records nothing outside a request" do
      user.update!(name: "Example Name")

      expect(described_class.drain).to be_empty
    end
  end

  describe "naming the endpoint", type: :request do
    include Devise::Test::IntegrationHelpers

    it "uses controller#action for a routed request" do
      sign_in create(:user, global_role: "global_admin")

      # Devise stamps the sign-in on the first request of the session.
      get admin_bans_path

      expect(described_class.drain.map { |write| [ write.endpoint, write.table ] }).to eq([ [ "admin/bans#index", "users" ] ])
    end
  end

  describe "the allowlist" do
    def write(endpoint:, sql:, database: "primary")
      described_class::Write.new(endpoint: endpoint, sql: sql, table: "examples", http_method: "GET", path: "/", database: database)
    end

    let(:allowlist) do
      described_class::Allowlist.new(
        databases: { "queue" => "jobs are queued from GETs" },
        global: [ { "sql" => 'UPDATE "tokens" SET "last_used_at"', "reason" => "throttled stamp" } ],
        actions: { "examples#show" => "creates the example on first view" }
      )
    end

    it "accepts anything a listed action writes" do
      expect(allowlist.allowed?(write(endpoint: "examples#show", sql: 'INSERT INTO "examples" DEFAULT VALUES'))).to be(true)
    end

    it "accepts a listed statement wherever it happens" do
      sql = %(UPDATE "tokens" SET "last_used_at" = $1 WHERE "tokens"."id" = $2)

      expect(allowlist.allowed?(write(endpoint: "anything#index", sql: sql))).to be(true)
    end

    # Production queues jobs and fills its cache through Active Record, on
    # connections of their own. A GET that queues a job hasn't written.
    it "accepts any write to a listed database, and the same write to the application's own is still caught" do
      sql = 'INSERT INTO "solid_queue_jobs" ("queue_name") VALUES ($1)'

      expect(allowlist.allowed?(write(endpoint: "examples#index", sql: sql, database: "queue"))).to be(true)
      expect(allowlist.allowed?(write(endpoint: "examples#index", sql: sql, database: "primary"))).to be(false)
    end

    it "rejects everything else" do
      expect(allowlist.allowed?(write(endpoint: "examples#index", sql: 'INSERT INTO "examples" DEFAULT VALUES'))).to be(false)
      expect(allowlist.allowed?(write(endpoint: "anything#index", sql: 'UPDATE "tokens" SET "revoked_at" = $1'))).to be(false)
    end

    it "gives every entry in the real file a reason" do
      data = YAML.safe_load_file(described_class::ALLOWLIST_PATH)

      expect(data.fetch("databases")).to all(satisfy { |database, reason| database.present? && reason.present? })
      expect(data.fetch("global")).to all(include("sql" => be_present, "reason" => be_present))
      expect(data.fetch("actions")).to all(satisfy { |endpoint, reason| endpoint.include?("#") && reason.present? })
    end

    it "lists the queue, cache and cable databases, and never the application's own" do
      expect(described_class.allowlist.databases).to include("queue", "cache", "cable")
      expect(described_class.allowlist.databases).not_to include("primary", "primary_replica")
    end

    it "records which database a write went to" do
      writes = rack_request("GET") { User.where(id: user.id).update_all(name: "Example Name") }

      expect(writes.sole.database).to eq(User.connection_db_config.name)
    end

    it "only lists actions that exist" do
      missing = described_class.allowlist.actions.reject do |endpoint|
        controller_path, action = endpoint.split("#")
        "#{controller_path}_controller".camelize.safe_constantize&.action_methods&.include?(action)
      end

      expect(missing).to be_empty
    end
  end
end
