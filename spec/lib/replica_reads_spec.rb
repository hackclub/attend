require "rails_helper"

RSpec.describe ReplicaReads do
  def with_env(values)
    saved = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  describe ".enabled?" do
    it "is off by default" do
      expect(ENV[described_class::FLAG]).to be_nil
      expect(described_class.enabled?).to be(false)
    end

    it "stays off with the flag set when there is no replica to read from" do
      with_env(described_class::FLAG => "1") do
        expect(described_class.replica_configured?).to be(false)
        expect(described_class.enabled?).to be(false)
      end
    end

    context "with a replica configured" do
      include_context "with a reading role"

      it "needs the flag as well" do
        expect(described_class.replica_configured?).to be(true)
        expect(described_class.enabled?).to be(false)
      end

      it "is on once the flag is set to a true value" do
        %w[1 true on].each do |value|
          with_env(described_class::FLAG => value) { expect(described_class.enabled?).to be(true) }
        end
        %w[0 false off].each do |value|
          with_env(described_class::FLAG => value) { expect(described_class.enabled?).to be(false) }
        end
      end
    end
  end

  describe ".decide" do
    def decide(**overrides)
      described_class.decide(http_method: "GET", endpoint: "admin/bans#index", **overrides)
    end

    it "keeps everything on the primary while switched off" do
      expect(decide).to have_attributes(role: :writing, reason: :disabled)
    end

    context "when switched on" do
      before { allow(described_class).to receive(:enabled?).and_return(true) }

      it "sends a GET or HEAD from a routed controller to the replica" do
        expect(decide).to have_attributes(role: :reading, reason: :read_only)
        expect(decide(http_method: "HEAD")).to have_attributes(role: :reading)
        expect(decide(http_method: :get)).to have_attributes(role: :reading)
      end

      it "keeps every other method on the primary" do
        %w[POST PATCH PUT DELETE].each do |http_method|
          expect(decide(http_method: http_method)).to have_attributes(role: :writing, reason: :unsafe_method)
        end
      end

      it "keeps controllers that don't take part on the primary" do
        expect(decide(endpoint: "onboarding#show", routed: false)).to have_attributes(role: :writing, reason: :not_routed)
      end

      it "keeps a GET that is known to write on the primary" do
        expect(decide(endpoint: "admin/rooming_wizard#setup")).to have_attributes(role: :writing, reason: :writes_on_get)
        expect(decide(endpoint: "api/v1/inbox_messages#show")).to have_attributes(role: :writing, reason: :writes_on_get)
      end

      it "keeps reads on the primary just after a write, and only asks when it matters" do
        expect(decide(recently_wrote: true)).to have_attributes(role: :writing, reason: :recent_write)
        expect(decide(recently_wrote: -> { true })).to have_attributes(role: :writing, reason: :recent_write)
        expect(decide(recently_wrote: -> { false })).to have_attributes(role: :reading)

        never_asked = -> { raise "should not be asked" }
        expect(decide(http_method: "POST", recently_wrote: never_asked)).to have_attributes(role: :writing)
      end
    end
  end

  describe ".sticky_window" do
    it "defaults to five seconds and takes an override" do
      expect(described_class.sticky_window).to eq(5.seconds)
      with_env(described_class::STICKY_SECONDS_ENV => "30") { expect(described_class.sticky_window).to eq(30.seconds) }
      with_env(described_class::STICKY_SECONDS_ENV => "soon") { expect(described_class.sticky_window).to eq(5.seconds) }
    end
  end

  describe ".read_only_error?" do
    it "recognises Rails refusing a write, also when a view wrapped it" do
      error = ActiveRecord::ReadOnlyError.new("Write query attempted while in readonly mode")
      wrapped = begin
        begin
          raise error
        rescue ActiveRecord::ReadOnlyError
          raise ActionView::Template::Error.new(ActionView::Template.new("", "example", ->(*) { "" }, virtual_path: "example", format: :html, locals: []))
        end
      rescue ActionView::Template::Error => template_error
        template_error
      end

      expect(described_class.read_only_error?(error)).to be(true)
      expect(described_class.read_only_error?(wrapped)).to be(true)
      expect(described_class.read_only_error?(ActiveRecord::RecordNotFound.new)).to be(false)
    end
  end

  describe ".replica_unavailable_error?" do
    it "recognises a connection that couldn't be made or was lost, also when wrapped" do
      wrapped = begin
        begin
          raise PG::ConnectionBad, "could not connect to server"
        rescue PG::ConnectionBad
          raise ActiveRecord::ConnectionNotEstablished, "could not connect to server"
        end
      rescue ActiveRecord::ConnectionNotEstablished => error
        error
      end

      expect(described_class.replica_unavailable_error?(wrapped)).to be(true)
      expect(described_class.replica_unavailable_error?(ActiveRecord::ConnectionFailed.new("gone"))).to be(true)
      expect(described_class.replica_unavailable_error?(ActiveRecord::ReadOnlyError.new)).to be(false)
      expect(described_class.replica_unavailable_error?(ActiveRecord::RecordNotFound.new)).to be(false)
    end
  end

  describe "switching roles" do
    include_context "with a reading role"

    let!(:user) { create(:user) }

    it "reads app models on the reading role and refuses their writes" do
      described_class.reading do
        expect(User.current_role).to eq(:reading)
        expect(User.find(user.id)).to eq(user)
        expect { user.update!(name: "Example Name") }.to raise_error(ActiveRecord::ReadOnlyError)
      end

      expect(User.current_role).to eq(:writing)
      expect { user.update!(name: "Example Name") }.not_to raise_error
    end

    # Base.connected_to(role: :reading) would switch these too, and the ones
    # with a pool of their own have no reading pool to switch to.
    it "leaves models that don't descend from ApplicationRecord on the primary, readable" do
      others = [ ActiveRecord::Base, PaperTrail::Version, Passkit::Pass, SolidQueue::Record, SolidCache::Record, SolidCable::Record ]
      others << Blazer::Record if defined?(Blazer::Record)

      described_class.reading do
        others.each { |model| expect(model.current_role).to eq(:writing), "#{model} switched role" }
        expect { PaperTrail::Version.count }.not_to raise_error
        expect { Passkit::Pass.count }.not_to raise_error
        expect { ActiveRecord::Base.connection.select_value("SELECT 1") }.not_to raise_error
      end
    end

    # They share the primary's pool with ApplicationRecord, and that pool is
    # what refuses writes. So a gem model writing inside a routed GET fails the
    # same way an app model does (and gets the same re-run on the primary),
    # never with a missing-pool error.
    it "refuses their writes the same way while a reading block is open" do
      described_class.reading do
        expect { PaperTrail::Version.create!(item_type: "User", item_id: user.id, event: "update") }
          .to raise_error(ActiveRecord::ReadOnlyError)
      end
    end

    it "lets a deliberate write through on the primary, and is a plain yield outside a reading block" do
      described_class.reading do
        described_class.on_primary { user.update_column(:name, "Written On Primary") }
        expect(User.current_role).to eq(:reading)
      end
      expect(user.reload.name).to eq("Written On Primary")

      expect(ApplicationRecord).not_to receive(:connected_to)
      expect(described_class.on_primary { :yielded }).to eq(:yielded)
    end

    it "stamps a throttled API token from inside a reading block" do
      token = MobileToken.generate_for(user)

      described_class.reading { token.touch_last_used! }

      expect(token.reload.last_used_at).to be_within(5.seconds).of(Time.current)
    end
  end
end
