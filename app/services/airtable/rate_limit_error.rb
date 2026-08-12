module Airtable
  class RateLimitError < Error
    private

    def default_message
      "Airtable rate limit exceeded"
    end
  end
end
