# Merges a duplicate Participant row into a primary one. Handles the case of
# one human ending up with two Participant rows — e.g. registering under two
# different email addresses — where data landing on the "other" row (a linked
# Slack account, a completed registration) is silently orphaned.
#
# Event registrations, sibling-group memberships, the headshot, the sign-in
# account link, and profile fields the primary is missing move onto the
# primary; the duplicate row is then deleted.
#
# Used by the admin merge tool and the participants:deduplicate rake task.
class ParticipantMergeService
  class Error < StandardError; end

  # Fields backfilled onto the primary when it has no real value of its own.
  # slack_user_id matters most: channel invites only see a slack_user_id on
  # the same row as the completed ParticipantEvent.
  PROFILE_FIELDS = %i[
    legal_first_name legal_last_name preferred_name date_of_birth
    phone pronouns address_line_1 address_line_2 city state
    postal_code country_of_residence tshirt_size engagement_preference
    engagement_notes slack_user_id
  ].freeze

  # Placeholder onboarding writes for required name fields when OIDC claims
  # are missing — treated the same as blank.
  PLACEHOLDER = "Unknown"

  # When both rows registered for the same event, the more-progressed
  # registration is kept and the other destroyed. Ties keep the primary's.
  STATUS_PRIORITY = {
    "complete" => 4,
    "awaiting_guardian" => 3,
    "in_progress" => 2,
    "invited" => 1
  }.freeze

  def initialize(primary:, duplicate:)
    @primary = primary
    @duplicate = duplicate
  end

  # Describes what merge! would do, without changing anything.
  def preview
    validate!
    build_actions(execute: false)
  end

  # Performs the merge and returns the list of actions taken. Raises (and
  # rolls back) on failure, leaving both rows untouched.
  def merge!
    validate!

    ActiveRecord::Base.transaction do
      actions = build_actions(execute: true)
      # Reload so dependent-destroy doesn't chase associations that were
      # already moved to the primary within this transaction.
      duplicate.reload.destroy!
      primary.save!
      actions
    end
  end

  private

  attr_reader :primary, :duplicate

  def validate!
    raise Error, "a participant cannot be merged into itself" if primary.id == duplicate.id
    raise Error, "both participants must be persisted" unless primary.persisted? && duplicate.persisted?
  end

  def build_actions(execute:)
    actions = []
    merge_participant_events(actions, execute:)
    merge_sibling_memberships(actions, execute:)
    merge_profile_fields(actions, execute:)
    merge_headshot(actions, execute:)
    merge_user_link(actions, execute:)
    actions
  end

  def merge_participant_events(actions, execute:)
    duplicate.participant_events.order(:created_at).to_a.each do |pe|
      existing = primary.participant_events.find_by(event_id: pe.event_id)

      if existing.nil?
        actions << "Transfer #{pe.event.name} registration (#{pe.status})"
        pe.update!(participant: primary) if execute
      elsif status_priority(pe.status) > status_priority(existing.status)
        actions << "Replace this record's #{pe.event.name} registration (#{existing.status}) " \
                   "with the duplicate's more progressed one (#{pe.status})"
        if execute
          existing.destroy!
          pe.update!(participant: primary)
        end
      else
        actions << "Delete the duplicate's #{pe.event.name} registration (#{pe.status}) — " \
                   "this record's (#{existing.status}) is kept"
        pe.destroy! if execute
      end
    end
  end

  def merge_sibling_memberships(actions, execute:)
    duplicate.sibling_memberships.to_a.each do |membership|
      next if primary.sibling_memberships.exists?(sibling_group_id: membership.sibling_group_id)

      actions << "Transfer sibling group membership"
      membership.update!(participant: primary) if execute
    end
  end

  def merge_profile_fields(actions, execute:)
    PROFILE_FIELDS.each do |field|
      next unless missing?(primary.public_send(field)) && !missing?(duplicate.public_send(field))

      actions << "Copy #{field.to_s.humanize.downcase} from the duplicate"
      primary.public_send("#{field}=", duplicate.public_send(field)) if execute
    end
  end

  def merge_headshot(actions, execute:)
    return if primary.headshot.attached? || !duplicate.headshot.attached?

    actions << "Transfer headshot"
    # Destroying the duplicate purge_laters its attachment, but the shared
    # blob survives: Blob#purge no-ops while another attachment references it.
    primary.headshot.attach(duplicate.headshot.blob) if execute
  end

  def merge_user_link(actions, execute:)
    return if primary.user_id.present? || duplicate.user_id.blank?

    actions << "Link the duplicate's sign-in account"
    primary.user_id = duplicate.user_id if execute
  end

  def status_priority(status)
    STATUS_PRIORITY.fetch(status.to_s, 0)
  end

  def missing?(value)
    value.blank? || value == PLACEHOLDER
  end
end
