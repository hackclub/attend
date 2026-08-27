# frozen_string_literal: true

class MedicalPolicy < ApplicationPolicy
  def show?
    can_view?
  end

  def create?
    can_edit?
  end

  def update?
    can_edit?
  end

  # "limited" is here on purpose: the role exists to keep addresses and exact
  # birthdays away from staff who don't need them, not to leave them guessing
  # during a medical incident. Conditions and medications are the point.
  def show_full_details?
    return true if user.global_admin?
    return false unless event

    has_role?("safeguarding_lead", "event_admin", "limited")
  end

  # The trimmed-down medical view: allergies and dietary needs, no conditions
  # or medications.
  def show_limited?
    return true if user.global_admin?
    return false unless event

    has_role?("ops")
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user

      if user.global_admin?
        scope.all
      elsif (event = Current.event)
        user_roles = user.event_role_assignments.where(event: event).pluck(:role)
        if user_roles.intersect?(%w[event_admin ops limited safeguarding_lead])
          scope.joins(:participant_event).where(participant_events: { event_id: event.id })
        elsif user.participant
          scope.joins(:participant_event).where(participant_events: { event_id: event.id, participant_id: user.participant.id })
        else
          scope.none
        end
      else
        scope.none
      end
    end
  end

  private

  def can_view?
    return true if user.global_admin?
    return false unless event

    return true if has_role?("safeguarding_lead", "event_admin", "ops", "limited")
    return true if owns_record?

    false
  end

  def can_edit?
    return true if user.global_admin?
    return false unless event

    return true if has_role?("safeguarding_lead", "event_admin")
    return true if owns_record?

    false
  end

  def owns_record?
    user.participant && record.participant_event&.participant_id == user.participant.id
  end

  def event
    record.participant_event&.event
  end

  def has_role?(*roles)
    return false unless event

    user.event_role_assignments.exists?(event: event, role: roles)
  end
end
