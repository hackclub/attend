class IncidentParticipant < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :incident
  belongs_to :participant_event
end
