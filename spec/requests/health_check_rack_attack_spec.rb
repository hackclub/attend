require "rails_helper"

RSpec.describe "Health check and Rack::Attack", type: :request do
  # The initializer skips itself when solid_cache_entries is missing, which it
  # is in the test DB, so load the real rules by hand.
  before do
    @original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    allow(ActiveRecord::Base.connection).to receive(:table_exists?).and_call_original
    allow(ActiveRecord::Base.connection).to receive(:table_exists?).with("solid_cache_entries").and_return(true)
    load Rails.root.join("config/initializers/rack_attack.rb")
  end

  after do
    Rack::Attack.clear_configuration
    Rack::Attack.cache.store = @original_store
  end

  it "loads the throttle rules" do
    expect(Rack::Attack.throttles).to include("req/ip")
  end

  it "does not touch the cache store for /up" do
    expect(Rack::Attack.cache.store).not_to receive(:increment)
    expect(Rack::Attack.cache.store).not_to receive(:read)

    get "/up"

    expect(response).to have_http_status(:ok)
  end

  it "never throttles /up" do
    301.times { get "/up" }

    expect(response).to have_http_status(:ok)
  end
end
