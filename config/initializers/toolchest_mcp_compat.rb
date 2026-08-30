# Bridges toolchest 0.3.x onto the mcp gem's hardened (>= 0.23) transport.
#
# toolchest builds and wires the MCP server itself and exposes no seam for any of
# this, so each piece below reaches in after `Toolchest::RackApp` initializes.
# Drop the corresponding shim as toolchest grows real support for it.
require "toolchest"

module ToolchestMcpCompat
  # Toolchest 0.3 installs handlers against mcp 0.11's contracts. Current mcp
  # versions expect list handlers to return the named result object, and dispatch
  # several APIs through dedicated server methods instead of the handler table.
  # Normalize both surfaces here so legacy and modern clients receive the current
  # protocol shapes while Toolchest still owns routing and authorization.
  def self.install_current_api!(server, router)
    handlers = server.instance_variable_get(:@handlers)
    handlers[MCP::Methods::TOOLS_LIST] = ->(_params) { { tools: router.tools_for_handler } }
    handlers[MCP::Methods::RESOURCES_LIST] = ->(_params) { { resources: router.resources_for_handler } }
    handlers[MCP::Methods::RESOURCES_TEMPLATES_LIST] = ->(_params) do
      { resourceTemplates: router.resource_templates_for_handler }
    end
    handlers[MCP::Methods::PROMPTS_LIST] = ->(_params) { { prompts: router.prompts_for_handler } }

    install_prompt_handler!(server, router)
    install_resource_handler!(server, router)
    relax_handler_signatures!(server)

    # Toolchest advertises list-change and logging features that it does not
    # implement on this stateless endpoint. Keep completions, which Toolchest
    # implements for enum-backed toolbox parameters, while advertising only the
    # APIs we actually serve.
    server.capabilities = { tools: {}, completions: {} }
    server.capabilities[:prompts] = {} if router.prompts_list.any?
    server.capabilities[:resources] = {} if router.toolbox_classes.any? { |toolbox| toolbox.resources.any? }
  end

  def self.install_prompt_handler!(server, router)
    server.define_singleton_method(:get_prompt) do |params, **_kwargs|
      name = params[:name] || params["name"]
      prompt = router.prompts_list.find { |candidate| candidate[:name] == name }
      unless prompt
        raise MCP::Server::RequestHandlerError.new(
          "Prompt not found: #{name}",
          params,
          error_type: :prompt_not_found,
          error_code: MCP::JsonRpcHandler::ErrorCode::INVALID_PARAMS
        )
      end

      arguments = params[:arguments] || params["arguments"] || {}
      unless arguments.is_a?(Hash)
        raise MCP::Server::RequestHandlerError.new("Invalid prompt arguments", params, error_type: :invalid_params)
      end

      missing = prompt[:arguments].filter_map do |argument_name, options|
        argument_name.to_s if options[:required] && !arguments.key?(argument_name.to_s) && !arguments.key?(argument_name.to_sym)
      end
      unless missing.empty?
        raise MCP::Server::RequestHandlerError.new(
          "Missing required prompt arguments: #{missing.join(", ")}",
          params,
          error_type: :invalid_params
        )
      end

      router.prompts_get(name, arguments)
    end
  end

  def self.install_resource_handler!(server, router)
    server.define_singleton_method(:read_resource_contents) do |params, **_kwargs|
      uri = params[:uri] || params["uri"]
      resource = router.toolbox_classes.flat_map(&:resources).find do |candidate|
        candidate[:template] ? uri&.match?(Regexp.new("^#{candidate[:uri].gsub(/\{[^}]+\}/, "[^/]+")}$")) : candidate[:uri] == uri
      end

      raise MCP::Server::ResourceNotFoundError.new(uri, params) unless resource

      router.resources_read(uri)
    end
  end

  # Current mcp versions pass request context keywords to the Toolchest
  # overrides. Forward only the keywords each old override declares.
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
    router = Toolchest.router(mount_key)
    ToolchestMcpCompat.install_current_api!(server, router)

    # `super` already built a stateful transport, which in mcp >= 0.23 spawns a
    # session-reaper thread. Shut it down rather than leaking the thread.
    instance_variable_get(:@transport)&.close

    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      # Attend is multi-process and multi-pod, with no shared notification bus.
      # Do not advertise or open an in-process subscriptions/listen stream that
      # would miss notifications emitted by the other workers.
      serve_subscriptions_listen: false,
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
