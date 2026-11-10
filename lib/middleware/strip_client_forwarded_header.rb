# Our ingress records the client in X-Forwarded-For and never sets the
# standard Forwarded header, so any Forwarded header that reaches us came
# from the client or a proxy on its side (Opera Mini's compression proxy
# sends one, for instance). Rack prefers Forwarded over X-Forwarded-For for
# the client IP, host and scheme, and ActionDispatch::RemoteIp raises
# IpSpoofAttackError when the two disagree, which they always do behind such a
# proxy. That raise happens while Rails logs the request, outside
# ShowExceptions, so the person got a bare 500.
#
# Dropping the header leaves X-Forwarded-For, the one our ingress writes, as
# the only source, which is also what should decide those values anyway.
class StripClientForwardedHeader
  def initialize(app)
    @app = app
  end

  def call(env)
    env.delete("HTTP_FORWARDED")
    @app.call(env)
  end
end
