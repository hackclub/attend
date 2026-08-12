class IncidentHelpingStaff < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail
  self.table_name = "incident_helping_staff"

  belongs_to :incident
  belongs_to :user
end
