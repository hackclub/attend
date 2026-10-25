module Airtable
  # 403: the token works but can't reach this base, table or sync source.
  class ForbiddenError < Error
    private

    def default_message
      "Airtable denied access"
    end
  end
end
