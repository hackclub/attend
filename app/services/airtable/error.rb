module Airtable
  class Error < StandardError
    attr_reader :response, :status

    def initialize(message = nil, response: nil)
      @response = response
      @status = response&.status
      super(message || default_message)
    end

    private

    def default_message
      "Airtable API error"
    end
  end
end
