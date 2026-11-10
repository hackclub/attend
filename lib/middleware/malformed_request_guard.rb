# Rack's MethodOverride reads the body of every POST to look for `_method`,
# and that sits above ActionDispatch::ShowExceptions. So a body Rack can't
# parse (an oversized multipart boundary, say) raised straight out to Puma
# as a bare 500. Rack tags every error that means "the client sent garbage"
# with Rack::BadRequest; answer those with a 400 here instead.
class MalformedRequestGuard
  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  rescue Rack::BadRequest
    [ 400, { "content-type" => "text/plain" }, [ "Bad Request" ] ]
  end
end
