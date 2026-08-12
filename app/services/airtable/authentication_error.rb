module Airtable
  class AuthenticationError < Error
    private

    def default_message
      "Invalid Airtable API key"
    end
  end
end
