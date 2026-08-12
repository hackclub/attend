module Docuseal
  class Error < StandardError
    attr_reader :response, :status

    def initialize(message = nil, response: nil, status: nil)
      @response = response
      @status = status
      super(message)
    end
  end

  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class NotFoundError < Error; end
  class ValidationError < Error; end
end
