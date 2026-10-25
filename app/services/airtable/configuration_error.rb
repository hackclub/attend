module Airtable
  # A key or base id is missing, so no request can be made. An ArgumentError
  # so callers that rescued the old bare ArgumentError keep working, but its
  # own class so the sync can tell it apart from an ArgumentError raised by a
  # bug.
  class ConfigurationError < ArgumentError; end
end
