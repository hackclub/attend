class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # primary_replica only exists when REPLICA_DATABASE_URL is set (see
  # config/database.yml). There is no automatic read/write-splitting middleware
  # — some GET requests write (e.g. guardian portals heal expired invites), so
  # replica reads are opt-in via `connected_to(role: :reading)`.
  if ActiveRecord::Base.configurations.configs_for(
    env_name: Rails.env, name: "primary_replica", include_hidden: true
  )
    connects_to database: { writing: :primary, reading: :primary_replica }
  end
end
