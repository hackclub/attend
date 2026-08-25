# The cache, queue and cable connections in config/database.yml point at the
# same database as primary, and the migrations_paths they name (db/queue_migrate
# and friends) do not exist — those tables come from db/<name>_schema.rb.
#
# db:prepare only loads a schema when it creates the database. On a fresh
# database primary creates it and loads db/schema.rb; by the time the cache,
# queue and cable connections are prepared the database already exists, so each
# takes the "run pending migrations" path against an empty directory and their
# tables are never created. Booting then dies in Solid Queue's supervisor with
#
#   PG::UndefinedTable: relation "solid_queue_recurring_tasks" does not exist
#
# Production predates this setup and already has the tables, so it only shows up
# when standing up a new environment.
namespace :db do
  desc "Load db/<name>_schema.rb for secondary connections whose tables are missing"
  task ensure_secondary_schemas: :environment do
    sentinels = {
      "cache" => "solid_cache_entries",
      "queue" => "solid_queue_processes",
      "cable" => "solid_cable_messages"
    }

    sentinels.each do |name, sentinel|
      config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: name)
      next if config.nil?

      schema_file = Rails.root.join("db", "#{name}_schema.rb")
      next unless schema_file.exist?

      # Checked on the primary connection because every one of these configs
      # resolves to the same database; loading is skipped as soon as the tables
      # are there, which keeps this a no-op on every boot after the first.
      present = ActiveRecord::Base.connection_pool.with_connection { |c| c.table_exists?(sentinel) }
      next if present

      puts "[db] #{sentinel} missing — loading db/#{name}_schema.rb"
      ActiveRecord::Tasks::DatabaseTasks.load_schema(config, :ruby, schema_file.to_s)
    end
  end
end
