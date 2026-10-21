class Ban < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true

  has_many :ban_emails, dependent: :destroy
  accepts_nested_attributes_for :ban_emails, allow_destroy: true, reject_if: :all_blank
  has_many :ban_slack_ids, dependent: :destroy

  # manual: added by an admin here. ucat: mirrored nightly from the UCAT
  # conduct base by Bans::UcatSync, which owns adding and revoking these.
  enum :source, { manual: "manual", ucat: "ucat" }, default: :manual

  validate :identifies_someone

  # Active = not manually revoked and not past its expiry.
  scope :active, -> { where(revoked_at: nil).where("bans.expires_at IS NULL OR bans.expires_at > ?", Time.current) }

  # Single chokepoint used by every "add to event" path. Pass whatever Slack
  # IDs are known (from Hack Club Auth or the participant record); many paths
  # only have an email.
  def self.banned?(emails, slack_ids: [])
    emails = Array(emails).compact_blank.map { |email| email.strip.downcase }
    slack_ids = Array(slack_ids).compact_blank.map { |id| id.strip.upcase }

    (emails.any? && BanEmail.joins(:ban).merge(Ban.active).where("LOWER(ban_emails.email) IN (?)", emails).exists?) ||
      (slack_ids.any? && BanSlackId.joins(:ban).merge(Ban.active).where(slack_id: slack_ids).exists?)
  end

  # The Slack IDs we know for a participant, for passing to banned?.
  def self.slack_ids_for(participant)
    [ participant&.slack_user_id, participant&.user&.verified_slack_id ]
  end

  # A signed-in user, by their own email, their participant record's email,
  # and any Slack ID we know for either.
  def self.user_banned?(user)
    active_for_user(user).exists?
  end

  # Everything we'd match a user on, normalised the way banned? does. Uses
  # every participant row that is this person (see User#participant_records),
  # not just the linked one: an imported row under another address still
  # belongs to them, and a ban on that address has to stop them.
  def self.identity_of(user)
    participants = user.participant_records.to_a
    {
      emails: ([ user.email ] + participants.map(&:email)).compact_blank.map { |email| email.strip.downcase }.uniq,
      slack_ids: ([ user.verified_slack_id, user.slack_user_id ] + participants.map(&:slack_user_id)).compact_blank.map { |id| id.strip.upcase }.uniq
    }
  end

  # The active bans behind user_banned?, for showing an admin which ban(s)
  # apply and why. user_banned? is defined on top of this, so the two can't
  # disagree.
  def self.active_for_user(user)
    return none if user.nil?

    identity = identity_of(user)
    by_email = identity[:emails].any? ? BanEmail.where("LOWER(ban_emails.email) IN (?)", identity[:emails]).select(:ban_id) : BanEmail.none.select(:ban_id)
    by_slack = identity[:slack_ids].any? ? BanSlackId.where(slack_id: identity[:slack_ids]).select(:ban_id) : BanSlackId.none.select(:ban_id)

    active.where(id: by_email).or(active.where(id: by_slack)).includes(:ban_emails, :ban_slack_ids).order(created_at: :desc)
  end

  # Which of this ban's identifiers belong to the user, as display strings.
  # A synced ban can carry a person's other addresses; those aren't shown
  # against a user they don't belong to.
  def identifiers_matching(user)
    identity = self.class.identity_of(user)
    ban_emails.map(&:email).select { identity[:emails].include?(_1.to_s.strip.downcase) } +
      ban_slack_ids.map(&:slack_id).select { identity[:slack_ids].include?(_1) }.map { "Slack #{_1}" }
  end

  # Enrollments on events that haven't ended whose participant is on an active
  # ban by email or Slack ID. Ban.banned? only stops new adds, so these are
  # people who got in before the ban, or whose Slack ID only became known
  # after they signed in with Hack Club Auth.
  def self.upcoming_enrollments
    emails = BanEmail.joins(:ban).merge(Ban.active).select("LOWER(ban_emails.email)").to_sql
    slack_ids = BanSlackId.joins(:ban).merge(Ban.active).select("ban_slack_ids.slack_id").to_sql

    ParticipantEvent.joins(:participant, :event)
      .joins("LEFT JOIN users ON users.id = participants.user_id")
      .merge(Event.not_ended)
      .where.not(status: %w[withdrawn rejected])
      .where(<<~SQL.squish)
        LOWER(participants.email) IN (#{emails})
        OR UPPER(participants.slack_user_id) IN (#{slack_ids})
        OR UPPER(participant_events.slack_user_id) IN (#{slack_ids})
        OR users.verified_slack_id IN (#{slack_ids})
      SQL
      .includes(:participant, :event)
  end

  # [[label, airtable url], ...] for the UCAT cases behind a synced ban.
  # Cases synced before record IDs were stored have no link.
  def ucat_case_links
    Array(ucat_cases).map do |c|
      url = c["record_id"].present? ? "https://airtable.com/#{Bans::UcatSync::BASE_ID}/#{Bans::UcatSync::TABLE_ID}/#{c['record_id']}" : nil
      [ c["id"].to_s, url ]
    end
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
    slack_ids = ban_slack_ids.map(&:slack_id)
    return Participant.none if emails.empty? && slack_ids.empty?

    Participant.left_joins(:user)
      .where("LOWER(participants.email) IN (?) OR UPPER(participants.slack_user_id) IN (?) OR users.verified_slack_id IN (?)", emails, slack_ids, slack_ids)
      .includes(:events)
  end

  private

  def identifies_someone
    return if ban_emails.any? { |e| !e.marked_for_destruction? } || ban_slack_ids.any? { |s| !s.marked_for_destruction? }

    errors.add(:ban_emails, :blank)
  end
end
