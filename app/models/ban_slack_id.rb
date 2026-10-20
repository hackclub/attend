class BanSlackId < ApplicationRecord
  self.implicit_order_column = "created_at"

  FORMAT = /\A[UW][A-Z0-9]{6,}\z/

  has_paper_trail

  belongs_to :ban

  normalizes :slack_id, with: ->(id) { id.strip.upcase }

  validates :slack_id, presence: true, format: { with: FORMAT }
  validates :slack_id, uniqueness: { message: "is already on a ban list" }
end
