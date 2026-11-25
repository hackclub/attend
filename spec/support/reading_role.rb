# Gives ApplicationRecord a reading role for the examples that include it, so
# the role switch ReplicaReads does can be exercised without a second
# database.
#
# It is wired the way production is when REPLICA_DATABASE_URL is set
# (ApplicationRecord.connects_to with a writing and a reading database), with
# both roles pointing at the test database. Transactional fixtures then fold
# the reading pool into the writing one, as Rails does for any app with a
# replica, so "replica" reads see the example's uncommitted rows.
#
# What that means for what these examples prove: role selection and Rails
# refusing writes on the reading role are real. A physical standby is not
# involved, so replication lag and the standby's own refusals (row locks, for
# one) are not exercised.
RSpec.shared_context "with a reading role" do
  before(:all) do
    @reading_role_descriptor = ApplicationRecord.connection_pool.pool_config.connection_descriptor
    @reading_role_connection_class = ApplicationRecord.connection_class?
    ApplicationRecord.connects_to database: { writing: :primary, reading: :primary }
  end

  after(:all) do
    ActiveRecord::Base.connection_handler.remove_connection_pool(
      ApplicationRecord.connection_specification_name, role: ActiveRecord.reading_role
    )
    ApplicationRecord.connection_class = @reading_role_connection_class
    ApplicationRecord.connection_pool.pool_config.connection_descriptor = @reading_role_descriptor
  end
end
