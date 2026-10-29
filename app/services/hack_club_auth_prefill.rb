# Details Attend already knows about someone arriving from an invitation,
# sent along on the Hack Club Auth authorize URL so a new account's signup
# form starts filled in (see "Prefilling user information" in HCA's OAuth
# guide). People who already have an HCA account never see them, and every
# prefilled field stays editable.
#
# These ride along as query parameters on the authorize URL, so anyone who
# opens a forwarded invitation link sees the invitee's details on HCA's
# signup form. Only open, unaccepted invitations prefill anything.
class HackClubAuthPrefill
  def self.from_session(session)
    token = session&.[]("invitation_token")
    return {} if token.blank?

    invitation = Invitation.find_by(token: token)
    return {} if invitation.nil? || invitation.expired? || invitation.accepted?

    new(invitation).params
  end

  def initialize(invitation)
    @invitation = invitation
  end

  def params
    # Oldest first, like Api::V1::ParticipantsController#register_invitee.
    participant = Participant.where("LOWER(email) = ?", @invitation.email.downcase).order(:created_at).first

    {
      login_hint: @invitation.email,
      email: @invitation.email,
      # HCA's first_name is the everyday name it greets people by; its own
      # legal_first_name is a separate field. So send the preferred name when
      # there is one, the way #display_name and #greeting_name pick it.
      first_name: participant&.preferred_name.presence || real_name(participant&.legal_first_name),
      last_name: real_name(participant&.legal_last_name),
      birthday: participant&.date_of_birth&.iso8601,
      phone_number: participant&.phone.presence,
      country: CountryCodes.code_for(participant&.country_of_residence)
    }.compact
  end

  private

  def real_name(value)
    value unless Participant.name_placeholder?(value)
  end
end
