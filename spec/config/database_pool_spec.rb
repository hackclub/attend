require "rails_helper"

RSpec.describe "database connection pool" do
  it "sizes the Active Record pool from RAILS_MAX_THREADS" do
    # Guards the `pool:` key in database.yml — Active Record silently ignores
    # unknown keys (this was `max_connections:` once, leaving the pool at the
    # default 5 regardless of RAILS_MAX_THREADS).
    config = ActiveRecord::Base.connection_pool.db_config.configuration_hash
    expect(config[:pool]).to eq(ENV.fetch("RAILS_MAX_THREADS", 5).to_i)
  end
end
