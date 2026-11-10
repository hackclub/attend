# frozen_string_literal: true

# Who can read a participant note, in order:
#   1. Global admins read everything.
#   2. Restricted notes: event admins (incl. series members) and safeguarding
#      leads only, whatever visible_to_roles says.
#   3. Safeguarding leads read everything else on their event.
#   4. Authors read their own notes.
#   5. Safeguarding notes: nobody else.
#   6. Everyone else reads a note when its visible_to_roles is empty (meaning
#      "the whole event team") or names one of their roles.
class NotePolicy < ApplicationPolicy
  # Roles a note author can target with visible_to_roles. Safeguarding leads
  # always see every note, so they're not offered.
  SELECTABLE_ROLES = %w[event_admin ops limited].freeze

  def self.roles_for(user, event)
    return [] unless user && event

    roles = user.event_role_assignments.where(event: event).pluck(:role)
    roles |= [ "event_admin" ] if user.series_member_for_event?(event)
    roles
  end

  def index?
    has_any_role?
  end

  def show?
    can_view?
  end

  def create?
    return false if record.is_a?(Note) && record.restricted? && !Note.restricted_visible_to?(user, Current.event)

    has_any_role?
  end

  def update?
    can_edit?
  end

  def destroy?
    can_edit?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user
      return scope.all if user.global_admin?

      event = Current.event
      user_roles = NotePolicy.roles_for(user, event)
      return scope.none if user_roles.empty?

      base = scope.where(event: event).sensitivity_visible_to(user, event)
      return base if user_roles.include?("safeguarding_lead")

      non_safeguarding = base.where.not(note_type: "safeguarding").or(base.where(note_type: nil))
      non_safeguarding
        .where("COALESCE(cardinality(notes.visible_to_roles), 0) = 0 OR notes.visible_to_roles && ARRAY[?]::varchar[]", user_roles)
        .or(non_safeguarding.restricted)
        .or(base.where(author_user_id: user.id))
    end
  end

  private

  def can_view?
    return true if user.global_admin?
    return false unless record.event == Current.event

    user_roles = roles_for_event
    return false if user_roles.empty?

    if record.restricted?
      return false unless Note.restricted_visible_to?(user, Current.event)
      return true unless record.safeguarding?
    end

    return true if user_roles.include?("safeguarding_lead")
    return true if record.author_user_id == user.id

    return false if record.safeguarding?

    record.visible_to_roles.blank? || record.visible_to_roles.intersect?(user_roles)
  end

  def can_edit?
    return true if user.global_admin?
    return false unless record.event == Current.event

    return true if record.author_user_id == user.id

    user_roles = roles_for_event
    return true if user_roles.include?("event_admin")
    return true if record.safeguarding? && user_roles.include?("safeguarding_lead")

    false
  end

  def has_any_role?
    return true if user.global_admin?

    roles_for_event.any?
  end

  def roles_for_event
    @roles_for_event ||= NotePolicy.roles_for(user, Current.event)
  end
end
