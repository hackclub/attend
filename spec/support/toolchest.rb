# Toolchest's own RSpec helpers: `call_tool` dispatches through the real MCP
# router (scope filtering, before_actions, rescue_from and all) for specs
# tagged `type: :toolbox`.
require "toolchest/rspec"
