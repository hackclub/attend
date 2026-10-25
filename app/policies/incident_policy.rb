class IncidentPolicy < ApplicationPolicy
  def index?
    has_any_role?
  end

  def show?
    can_view_incident?
  end

  def create?
    has_any_role?
  end

  # Reporters can read and comment on what they filed, but changing it (and
  # who it's shared with) is for the roles it's shared with.
  def update?
    can_view_incident?(include_reporter: false)
  end

  def comment?
    can_view_incident?
  end

  # A reporter who holds none of the incident's roles gets a receipt: what they
  # submitted and where it stands, not the casework that followed it. The
  # actions taken and the comment thread are written by the people handling the
  # incident, and a safeguarding lead's follow-up is not the reporter's to read
  # just because they raised it. Everyone who can see the incident by role sees
  # all of it.
  def view_casework?
    can_view_incident?(include_reporter: false)
  end

  def escalate?
    can_view_incident?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user

      if user.global_admin?
        scope.all
      else
        user_roles = roles_for_current_event
        if user_roles.empty?
          scope.none
        else
          scope.visible_to_staff(user, user_roles)
        end
      end
    end

    private

    def roles_for_current_event
      event = Current.event
      return [] unless event

      user.event_role_assignments.where(event: event).pluck(:role)
    end
  end

  private

  def has_any_role?
    return true if user.global_admin?

    event = Current.event
    return false unless event

    user.event_role_assignments.exists?(event: event)
  end

  def can_view_incident?(include_reporter: true)
    return true if user.global_admin?

    event = Current.event
    return false unless event

    user_roles = user.event_role_assignments.where(event: event).pluck(:role)
    return false if user_roles.empty?

    # Reporters keep access to what they filed, whichever roles it's shared
    # with, for as long as they're still staff on the event.
    include_reporter ? record.visible_to_staff?(user, user_roles) : record.shared_with_roles?(user_roles)
  end
end
