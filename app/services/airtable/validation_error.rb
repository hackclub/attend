module Airtable
  class ValidationError < Error
    private

    def default_message
      "Invalid request to Airtable"
    end
  end
end
