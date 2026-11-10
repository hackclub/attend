# Request specs run with show_exceptions = :rescuable, so Rails turns an
# exception it knows (UnknownFormat, InvalidAuthenticityToken, ...) into the
# right status before the spec sees it. Production does the same, but the
# exception still reaches error tracking on the way. Tag an example
# `raise_exceptions: true` to make anything the app didn't handle itself
# raise, so a spec can tell "answered 406" from "raised, then shown as 406".
RSpec.configure do |config|
  config.around(:each, :raise_exceptions) do |example|
    env_config = Rails.application.env_config
    original = env_config["action_dispatch.show_exceptions"]
    env_config["action_dispatch.show_exceptions"] = :none
    example.run
  ensure
    env_config["action_dispatch.show_exceptions"] = original
  end
end
