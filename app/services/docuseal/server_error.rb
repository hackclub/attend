module Docuseal
  # 5xx: DocuSeal (or the proxy in front of it) is down or overloaded. Worth
  # retrying; nothing about the request itself is wrong. Its own file so
  # Zeitwerk can autoload it without error.rb having been loaded first.
  class ServerError < Error; end
end
