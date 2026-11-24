require "rails_helper"

# The companion to spec/models/audit_log_spec.rb. That spec holds every admin
# controller action to AuditLog's action enum, because the catch-all hook
# audits under the action's name. Operations audit under names they declare,
# so this holds every declared name to the same enum — and the base class
# refuses, at run time, an action that wasn't declared or a successful run
# that audited nothing.
RSpec.describe ApplicationOperation do
  let(:user) { create(:user, global_role: "global_admin") }
  let(:context) { Operation::Context.new(surface: :html, user: user) }

  def operations
    Rails.application.eager_load!
    described_class.descendants.select { |klass| klass.name.present? }
  end

  it "has every operation declare the audit actions it writes" do
    undeclared = operations.select { |klass| klass.declared_audit_actions.empty? }

    expect(undeclared.map(&:name)).to be_empty
  end

  it "only declares audit actions AuditLog's enum knows" do
    known = AuditLog.actions.keys.map(&:to_sym)

    unknown = operations.flat_map { |klass|
      (klass.declared_audit_actions - known).map { |action| "#{klass.name} declares #{action}" }
    }

    expect(unknown).to be_empty, "Add these to AuditLog's action enum:\n  #{unknown.join("\n  ")}"
  end

  it "refuses to audit an action the operation didn't declare" do
    operation = Class.new(described_class) do
      audit_actions :withdraw

      def initialize(context, record:)
        super(context)
        @record = record
      end

      def perform
        audit!(:export, @record)
        success
      end
    end

    expect { operation.call(context, record: create(:participant_event)) }
      .to raise_error(described_class::UndeclaredAuditAction)
    expect(AuditLog.count).to eq(0)
  end

  it "treats a successful run that audited nothing as a bug" do
    operation = Class.new(described_class) do
      audit_actions :withdraw

      def perform = success
    end

    expect { operation.call(context) }.to raise_error(described_class::UnauditedWrite)
  end

  it "does not ask a refused run for an audit row" do
    operation = Class.new(described_class) do
      audit_actions :withdraw

      def precheck = failure(:nope, "No.")
    end

    result = operation.call(context)

    expect(result).to be_failure
    expect(result.code).to eq(:nope)
  end

  it "refuses to run on an anonymized connection" do
    operation = Class.new(described_class) do
      audit_actions :withdraw

      def perform = raise("should not run")
    end
    anonymized = Operation::Context.new(surface: :mcp, user: user, anonymized: true)

    expect(operation.call(anonymized).code).to eq(:anonymized)
  end

  it "refuses an API key unless the check lets keys through" do
    operation = Class.new(described_class) do
      audit_actions :withdraw

      def self.name = "Probe"

      def initialize(context, record:)
        super(context)
        @record = record
      end

      def precheck
        authorize!(@record, :update?)
        nil
      end

      def perform = success
    end
    key_context = Operation::Context.new(surface: :api, user: nil, actor: user, api_key: true)

    expect { operation.call(key_context, record: create(:participant_event)) }
      .to raise_error(Pundit::NotAuthorizedError)
  end

  describe "the audit row" do
    let(:event) { create(:event) }
    let(:participant_event) { create(:participant_event, event: event) }
    let(:context) do
      Operation::Context.new(surface: :html, user: user, event: event,
        metadata: { controller: "participants", params: { "guardian" => { "city" => "Springfield" } } })
    end

    it "carries the actor, event, operation name and surface, and remembers the record on the context" do
      note = Notes::Create.call(context, participant_event: participant_event,
        attributes: { body: "Arriving late.", note_type: "ops" }).value

      log = AuditLog.sole
      expect(log.action).to eq("record_create")
      expect(log.actor).to eq(user)
      expect(log.event).to eq(event)
      expect(log.record).to eq(note)
      expect(log.metadata).to include("operation" => "Notes::Create", "surface" => "html", "controller" => "participants")
      expect(log.metadata.dig("params", "guardian", "city")).to eq("[REDACTED]")
      expect(context.audited?).to be(true)
      expect(context.audited?(note)).to be(true)
      expect(context.audited?(participant_event.participant)).to be(false)
    end

    # In production a failed audit write is reported, not raised. The context
    # must not claim the row exists, or the surface's catch-all hook stands
    # down and the write ends up with no row at all.
    it "leaves the context unaudited when the row can't be written" do
      allow(Rails.env).to receive(:local?).and_return(false)
      allow(AuditLog).to receive(:log!).and_raise(ActiveRecord::StatementInvalid, "audit_logs is unavailable")

      result = Notes::Create.call(context, participant_event: participant_event,
        attributes: { body: "Arriving late.", note_type: "ops" })

      expect(result).to be_success
      expect(context.audited?).to be(false)
      expect(context.audited?(result.value)).to be(false)
    end
  end
end
