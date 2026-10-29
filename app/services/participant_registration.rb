# Putting someone on an event's roster ahead of onboarding: an integration's
# invitation through the API, and a visa letter applicant offered a place.
module ParticipantRegistration
  # Puts the invitee on the roster immediately, in the same `invited` state
  # a CSV import leaves them in, so staff can see them and the "Incomplete
  # Onboarding" message audience can reach them before they ever sign in.
  # Onboarding links the person to their account by email and moves them to
  # `in_progress` the moment they open the wizard.
  #
  # `invited` specifically, never `in_progress`: ParticipantEvent#onboarding_held?
  # keys off that status, and it is what keeps the wizard shut for someone
  # whose invitation is still held by the event.
  #
  # `participant` is someone the caller already knows is them (a visa
  # applicant's Hack Club account). Otherwise they're found by email.
  #
  # Yields the participant when details were filled in on an existing record,
  # so the caller can audit-log the change its own way.
  def self.register_invitee!(event:, email:, first_name:, last_name:, details: {}, participant: nil)
    # LOWER() rather than an exact match: participant emails are not
    # normalized on write, so an existing person may be stored in another
    # case. Missing them here would fork the same human into two records.
    # Oldest first: duplicate rows for one address exist in production,
    # and without an order the pick would vary between invitations.
    participant ||= Participant.where("LOWER(participants.email) = ?", email.to_s.downcase).order(:created_at).first

    if participant
      # Someone Attend already knows (from another event): only fill in
      # what's missing, never overwrite what they entered themselves.
      # Skip the save when there's nothing to fill in: an older record
      # may not pass today's validations, and that shouldn't fail an
      # invite that changes nothing.
      known = { legal_first_name: first_name.presence, legal_last_name: last_name.presence, **details }.compact
      fills = participant.blank_attributes_only(known)
      if fills.any?
        participant.update!(fills)
        yield participant if block_given?
      end
    else
      participant = Participant.create!(
        email: email,
        # Legal names are validated on every save, but an invitation may
        # only carry an address. "Unknown" is the placeholder the
        # onboarding OIDC backfill looks for, so the real name lands on
        # first sign-in.
        legal_first_name: first_name.presence || Participant::NAME_PLACEHOLDER,
        legal_last_name: last_name.presence || Participant::NAME_PLACEHOLDER,
        **details
      )
    end

    # The birthday is kept even if it ages them out; onboarding holds them
    # until staff sort it out (see ParticipantEvent#skip_age_check).
    ParticipantEvent.create_with(status: :invited, skip_age_check: true)
                    .find_or_create_by!(participant: participant, event: event)
  end
end
