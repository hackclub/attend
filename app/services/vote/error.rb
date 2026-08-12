module Vote
  class Error < StandardError
    attr_reader :response, :status

    def initialize(message = nil, response: nil, status: nil)
      @response = response
      @status = status
      super(message)
    end
  end
end
