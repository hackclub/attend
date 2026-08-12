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

  def update?
    can_view_incident?
  end

  def send_to_slack?
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
          scope.for_roles(user_roles)
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

  def can_view_incident?
    return true if user.global_admin?

    event = Current.event
    return false unless event

    user_roles = user.event_role_assignments.where(event: event).pluck(:role)
    return false if user_roles.empty?

    (record.visible_to_roles & user_roles).any?
  end
end
