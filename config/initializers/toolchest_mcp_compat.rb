# Bridges toolchest 0.3.x onto the mcp gem's hardened (>= 0.23) transport.
#
# toolchest builds and wires the MCP server itself and exposes no seam for any of
# this, so each piece below reaches in after `Toolchest::RackApp` initializes.
# Drop the corresponding shim as toolchest grows real support for it.
require "toolchest"

module ToolchestMcpCompat
  # mcp 0.23 passes a `cancellation:` keyword down to `MCP::Server#call_tool` and
  # `#complete`. toolchest's singleton overrides of both predate it and accept only
  # `session:`/`related_request_id:`, so every tools/call would raise ArgumentError.
  # Re-wrap them to pass on just the keywords the override actually declares.
  def self.relax_handler_signatures!(server)
    [ :call_tool, :complete ].each do |name|
      next unless server.singleton_class.method_defined?(name) ||
        server.singleton_class.private_method_defined?(name)

      inner = server.singleton_method(name)
      # A `**kwargs` override already tolerates anything mcp adds.
      next if inner.parameters.any? { |type, _| type == :keyrest }

      accepted = inner.parameters.filter_map { |type, key| key if [ :key, :keyreq ].include?(type) }

      server.define_singleton_method(name) do |params, **kwargs|
        inner.call(params, **kwargs.slice(*accepted))
      end
    end
  end
end

# mcp 0.23 validates the `Host` header itself (CVE-2026-63118) against an allow
# list that defaults to loopback only, and toolchest passes no `allowed_hosts:`.
# Attend is not loopback, and Rails already runs exactly this check upstream via
# `config.hosts` (ActionDispatch::HostAuthorization) using regexps and
# per-environment entries that mcp's plain-string allow list can't express.
# Defer to Rails so the two lists can never diverge; mcp's `Origin` check, which
# Rails has no equivalent for, is left alone.
module ToolchestRailsHostAuthorization
  private

  def validate_host(request)
    host = request.env["HTTP_HOST"]
    return if host.nil?

    permissions = ActionDispatch::HostAuthorization::Permissions.new(Rails.application.config.hosts)
    return if permissions.empty? || permissions.allows?(host)

    super
  end
end

# Run the MCP transport statelessly.
#
# Toolchest builds an MCP StreamableHTTPTransport that keeps session state in
# the worker's memory. Attend runs multiple Puma workers (WEB_CONCURRENCY) and
# multiple pods, so a follow-up request can land on a different process than the
# one that ran `initialize`, which then rejects it with "Missing session ID".
# Stateless mode makes every request self-contained, so it works regardless of
# which worker/pod handles it — the right model for a horizontally-scaled,
# bearer-authenticated HTTP endpoint. It also sidesteps the session-retention and
# session-poisoning advisories outright: no sessions are ever stored.
#
# Trade-off: stateless mode can't push server-initiated notifications
# (mcp_progress / mcp_sample / streamed logs). No toolbox relies on those.
module ToolchestStatelessTransport
  def initialize(*args, **kwargs)
    super

    server = instance_variable_get(:@server)
    ToolchestMcpCompat.relax_handler_signatures!(server)

    # `super` already built a stateful transport, which in mcp >= 0.23 spawns a
    # session-reaper thread. Shut it down rather than leaking the thread.
    instance_variable_get(:@transport)&.close

    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      # Same-origin and header-less (i.e. every non-browser) clients are always
      # accepted; a browser-based client such as the MCP Inspector sends its own
      # Origin and needs listing here, hence the escape hatch.
      allowed_origins: ENV.fetch("MCP_ALLOWED_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
    )
    server.transport = transport
    instance_variable_set(:@transport, transport)
  end
end

MCP::Server::Transports::StreamableHTTPTransport.prepend(ToolchestRailsHostAuthorization)
Toolchest::RackApp.prepend(ToolchestStatelessTransport)
