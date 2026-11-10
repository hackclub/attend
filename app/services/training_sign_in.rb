# Signing in to training with a code emailed to the address, for people who
# don't have a Hack Club account (most adult volunteers). A code only proves
# someone holds the inbox, so it's only for people who are on Attend just to
# train — volunteers and people invited to a course by hand — and the session
# it starts reaches /training and nothing else (see
# ApplicationController#confine_training_only_session). Anyone with access to
# more than training has to sign in with Hack Club Auth.
module TrainingSignIn
  # Marks a session as started from an emailed code.
  SESSION_KEY = :training_only_sign_in

  def self.eligible?(user)
    return false if user.nil?
    return false if user.hack_club_account_id.present?
    return false unless user.no_role?
    return false if user.event_role_assignments.exists? || user.series_role_assignments.exists?
    return false if user.participant_records.exists?

    user.event_volunteers.exists? || user.training_course_invitations.exists?
  end
end
