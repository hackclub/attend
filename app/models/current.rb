class Current < ActiveSupport::CurrentAttributes
  attribute :user
  attribute :event
  attribute :request_id
  attribute :ip_address
  attribute :aero_airport_info_memo
end
