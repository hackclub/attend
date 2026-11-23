# Finds humans who ended up with more than one Participant row under the same
# email address, and works out which row should survive a merge.
#
# The usual cause: an import lands under a typo'd address, the person signs in
# with their real one and gets a fresh row, and an admin corrects the imported
# row's email afterwards — leaving the registrations on one row and the account
# link on another. See ParticipantMergeService for what merging actually moves.
#
# Nothing here writes. `groups` returns Group structs; the caller decides what
# to merge, and `Group#flags` says which pairs a human needs to look at first.
class DuplicateParticipantScan
  # A shared address is not proof of a shared identity — a parent's address on
  # two children's imported rows looks exactly like one person registering
  # twice. These are the signals that say "ask someone before merging".
  Group = Struct.new(:email, :rows, :primary, :flags, keyword_init: true) do
    def duplicates
      rows - [ primary ]
    end

    def safe?
      flags.empty?
    end
  end

  # Only matters to a merge, which would delete the row that owns the profile.
  # It says nothing about whether the rows are one person.
  PUBLIC_PROFILE_FLAG = "duplicate owns the public profile".freeze

  def initialize(emails: nil)
    @emails = emails&.map { |email| email.to_s.downcase.strip }&.reject(&:empty?)
  end

  def groups
    duplicate_emails.map { |email| build_group(email) }
  end

  def duplicate_emails
    scope = Participant.group("LOWER(email)").having("COUNT(*) > 1")
    found = scope.count.keys.map { |email| email.to_s.downcase }.sort
    return found if emails.nil?

    found & emails
  end

  # Addresses the caller asked about that aren't actually duplicated (already
  # merged, or a typo in the list).
  def missing_emails
    return [] if emails.nil?

    emails - duplicate_emails
  end

  # The signals that rows sharing an address may not be one human. Reads only
  # legal_first_name, legal_last_name, date_of_birth and user_id, so it works
  # on light rows too (Identity::Backfill passes structs, not records).
  def identity_flags(rows)
    flags = []
    flags << "name mismatch" unless names_agree?(rows)
    flags << "date of birth mismatch" if rows.filter_map(&:date_of_birth).uniq.size > 1
    flags << "linked to different accounts" if rows.filter_map(&:user_id).uniq.size > 1
    flags
  end

  private

  attr_reader :emails

  def build_group(email)
    rows = Participant.where("LOWER(email) = ?", email).order(:created_at).to_a
    primary = pick_primary(rows)
    Group.new(email: email, rows: rows, primary: primary, flags: flags_for(rows, primary))
  end

  # Keep the row the sign-in account already points at — that is the one the
  # person's dashboard follows. Among several, keep whichever already holds the
  # most registrations, so a merge moves as little as possible; ties go to the
  # oldest row.
  def pick_primary(rows)
    linked = rows.select { |row| row.user_id.present? }
    pool = linked.any? ? linked : rows
    pool.max_by { |row| [ row.participant_events.count, -row.created_at.to_f ] }
  end

  def flags_for(rows, primary)
    flags = identity_flags(rows)

    # ParticipantMergeService doesn't carry public-profile fields across, so
    # merging away the row that owns an enabled profile would silently delete
    # someone's /p/ page and free up their slug.
    if (rows - [ primary ]).any?(&:public_profile_enabled?) && !primary.public_profile_enabled?
      flags << PUBLIC_PROFILE_FLAG
    end

    flags
  end

  def names_agree?(rows)
    Identity::NameMatch.agree?(rows.map { |row| [ row.legal_first_name, row.legal_last_name ] })
  end
end
