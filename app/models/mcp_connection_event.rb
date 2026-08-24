# One event an event-restricted MCP connection is allowed to reach.
class McpConnectionEvent < ApplicationRecord
  belongs_to :mcp_connection_setting
  belongs_to :event
end
