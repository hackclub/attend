# Toolchest's own RSpec helpers: `call_tool` dispatches through the real MCP
# router (scope filtering, before_actions, rescue_from and all) for specs
# tagged `type: :toolbox`.
require "toolchest/rspec"

# A tool call sets Current.user, and nothing clears it between examples the
# way Rails does between requests. Left behind, the next example sees a user
# whose row was rolled back.
RSpec.configure do |config|
  config.after(:each, type: :toolbox) { Current.reset }
end
