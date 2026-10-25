class IncidentMedication < ApplicationRecord
  has_paper_trail skip: [ :name, :dose, :notes ]

  self.implicit_order_column = "created_at"

  encrypts :name, :dose, :notes

  belongs_to :incident

  validates :name, presence: true
  validates :dose, presence: true
end
