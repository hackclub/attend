# Who sees and decides broadcasts BroadcastScreener held back.
#
# Global admins review everything. Series owners review held broadcasts for
# events in their series, but not ones they wrote, edited or sent: the screen
# is a second pair of eyes, so an owner can't wave their own message through.
# Organizers, event staff and everyone else only see a held message from the
# message's own page.
class BroadcastReviewPolicy < ApplicationPolicy
  def index?
    user.global_admin? || owned_series_ids.exists?
  end

  def show?
    user.global_admin? || series_owner_for_review?
  end

  def decide?
    return true if user.global_admin?

    series_owner_for_review? && !had_a_hand_in_it?
  end

  # Whether this user wrote, edited or sent the held broadcast. Pressing Send
  # isn't the only way in: an owner could draft it and have someone else send
  # it, or edit an organizer's draft, so any PaperTrail version they made
  # counts too.
  def had_a_hand_in_it?
    return true if record.submitted_by_user_id == user.id

    reviewable = record.reviewable
    return false unless reviewable

    reviewable.sent_by_user_id == user.id ||
      reviewable.versions.where(whodunnit: user.id.to_s).exists?
  end

  def approve_broadcast?
    decide?
  end

  def reject_broadcast?
    decide?
  end

  # Picking who gets the "held for review" emails is app-wide.
  def manage_recipients?
    user.global_admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.all if user.global_admin?

      owned = user.series_role_assignments.owner.select(:event_series_id)
      scope.where(event_id: Event.where(event_series_id: owned).select(:id))
    end
  end

  private

  def owned_series_ids
    user.series_role_assignments.owner
  end

  def series_owner_for_review?
    series_id = record.event&.event_series_id
    series_id.present? && owned_series_ids.exists?(event_series_id: series_id)
  end
end
