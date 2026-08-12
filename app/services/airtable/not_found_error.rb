module Airtable
  class NotFoundError < Error
    private

    def default_message
      "Airtable resource not found"
    end
  end
end
