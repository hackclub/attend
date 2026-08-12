module Airtable
  # 5xx from Airtable: their side is unhealthy, not our configuration.
  class ServerError < Error
    private

    def default_message
      "Airtable server error"
    end
  end
end
