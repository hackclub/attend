# Run the MCP transport statelessly.
#
# Toolchest builds an MCP StreamableHTTPTransport that keeps session state in
# the worker's memory. Attend runs multiple Puma workers (WEB_CONCURRENCY) and
# multiple pods, so a follow-up request can land on a different process than the
# one that ran `initialize`, which then rejects it with "Missing session ID".
# Stateless mode makes every request self-contained, so it works regardless of
# which worker/pod handles it — the right model for a horizontally-scaled,
# bearer-authenticated HTTP endpoint.
#
# Trade-off: stateless mode can't push server-initiated notifications
# (mcp_progress / mcp_sample / streamed logs). No toolbox relies on those.
#
# Toolchest doesn't expose the transport constructor, so rebuild it after the
# RackApp initializes. Drop this shim if toolchest gains transport config.
require "toolchest"

module ToolchestStatelessTransport
  def initialize(*args, **kwargs)
    super

    server = instance_variable_get(:@server)
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true)
    server.transport = transport
    instance_variable_set(:@transport, transport)
  end
end

Toolchest::RackApp.prepend(ToolchestStatelessTransport)
