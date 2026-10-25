module Airtable
  # A 429 for the workspace's monthly API call allowance rather than a burst
  # over 5 requests a second. Retrying won't help until the plan changes or
  # the month rolls over.
  class QuotaExceededError < Error
    private

    def default_message
      "Airtable monthly API call limit reached"
    end
  end
end
