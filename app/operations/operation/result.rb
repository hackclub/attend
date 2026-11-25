module Operation
  # What every operation hands back. A failure carries a machine-readable
  # `code` for the surface to branch on and a plain `message` it can show as
  # is; `record` is the model whose validation failed, when that's what went
  # wrong.
  Result = Data.define(:value, :code, :message, :record) do
    def self.success(value = nil) = new(value: value, code: nil, message: nil, record: nil)

    def self.failure(code, message, record: nil) = new(value: nil, code: code.to_sym, message: message, record: record)

    def success? = code.nil?

    def failure? = !success?
  end
end
