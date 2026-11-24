module Operation
  # Raised by ApplicationOperation.call! for a failed Result, for callers that
  # want a failure to unwind (a surrounding transaction, a rescue_from).
  class Failure < StandardError
    attr_reader :result

    def initialize(result)
      @result = result
      super(result.message)
    end
  end
end
