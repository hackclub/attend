class IncidentComment < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail skip: [ :body ]

  encrypts :body

  belongs_to :incident
  belongs_to :user

  validates :body, presence: true

  after_create :update_incident_status, if: -> { new_status.present? }

  private

  def update_incident_status
    incident.update!(status: new_status)
  end
end
