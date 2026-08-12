# frozen_string_literal: true

class NotePolicy < ApplicationPolicy
  def index?
    has_any_role?
  end

  def show?
    can_view?
  end

  def create?
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

      if user.global_admin?
        scope.all
      elsif (event = Current.event)
        user_roles = user.event_role_assignments.where(event: event).pluck(:role)
        if user_roles.empty?
          scope.none
        else
          base_scope = scope.where(event: event)
          if user_roles.include?("safeguarding_lead")
            base_scope
          else
            base_scope.where.not(note_type: "safeguarding").for_roles(user_roles)
          end
        end
      else
        scope.none
      end
    end
  end

  private

  def can_view?
    return true if user.global_admin?
    return false unless record.event == Current.event

    user_roles = roles_for_event
    return false if user_roles.empty?

    return true if user_roles.include?("safeguarding_lead")

    return false if record.safeguarding?

    (record.visible_to_roles & user_roles).any?
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

    event = Current.event
    return false unless event

    user.event_role_assignments.exists?(event: event)
  end

  def roles_for_event
    event = Current.event
    return [] unless event

    user.event_role_assignments.where(event: event).pluck(:role)
  end
end
