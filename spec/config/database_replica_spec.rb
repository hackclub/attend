require "rails_helper"

RSpec.describe "config/database.yml replica configuration" do
  # Guards the ERB conditional in database.yml: primary_replica must appear
  # exactly when REPLICA_DATABASE_URL is set, marked replica so db:prepare in
  # the entrypoint never targets it, and pointing at the replica URL rather
  # than inheriting the primary's.
  def rendered_config(replica_url)
    original = ENV["REPLICA_DATABASE_URL"]
    ENV["REPLICA_DATABASE_URL"] = replica_url
    yaml = ERB.new(Rails.root.join("config/database.yml").read).result
    YAML.safe_load(yaml, aliases: true)
  ensure
    if original.nil?
      ENV.delete("REPLICA_DATABASE_URL")
    else
      ENV["REPLICA_DATABASE_URL"] = original
    end
  end

  context "when REPLICA_DATABASE_URL is set" do
    let(:url) { "postgresql://user:pass@pg-ro.example:5432/app" }

    it "defines primary_replica for production and staging" do
      config = rendered_config(url)

      %w[production staging].each do |env|
        replica = config.fetch(env)["primary_replica"]
        expect(replica).to be_present, "#{env} is missing primary_replica"
        expect(replica["url"]).to eq(url)
        expect(replica["replica"]).to be(true)
        expect(replica["database_tasks"]).to be(false)
      end
    end
  end

  context "when REPLICA_DATABASE_URL is not set" do
    it "omits primary_replica so connects_to keeps a single writer config" do
      config = rendered_config(nil)

      %w[production staging].each do |env|
        expect(config.fetch(env)).not_to have_key("primary_replica")
      end
    end
  end
end
