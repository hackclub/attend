class Ban < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true

  has_many :ban_emails, dependent: :destroy
  accepts_nested_attributes_for :ban_emails, allow_destroy: true, reject_if: :all_blank

  validates :ban_emails, presence: true

  # Active = not manually revoked and not past its expiry.
  scope :active, -> { where(revoked_at: nil).where("bans.expires_at IS NULL OR bans.expires_at > ?", Time.current) }

  # Single chokepoint used by every "add to event" path.
  def self.banned?(email)
    return false if email.blank?

    BanEmail.joins(:ban)
      .merge(Ban.active)
      .where("LOWER(ban_emails.email) = ?", email.strip.downcase)
      .exists?
  end

  def revoked?
    revoked_at.present?
  end

  # Lift the ban now but keep the record for history. Reversible via #reinstate!.
  def revoke!(by: nil)
    update!(revoked_at: Time.current, revoked_by: by)
  end

  def reinstate!
    update!(revoked_at: nil, revoked_by: nil)
  end

  def active?
    !revoked? && (expires_at.nil? || expires_at.future?)
  end

  def indefinite?
    expires_at.nil?
  end

  def status
    return "Revoked" if revoked?
    return "Indefinite" if indefinite?

    active? ? "Active" : "Expired"
  end

  # Participants already enrolled whose email matches one on this ban.
  # The ban does not remove them — this just surfaces who is affected.
  def affected_participants
    emails = ban_emails.map { |be| be.email&.downcase }.compact
    return Participant.none if emails.empty?

    Participant.where("LOWER(email) IN (?)", emails).includes(:events)
  end
end
