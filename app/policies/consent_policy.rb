# frozen_string_literal: true

class ConsentPolicy < ApplicationPolicy
  def index?
    can_view?
  end

  def show?
    can_view?
  end

  def create?
    can_edit?
  end

  def update?
    can_edit?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user

      if user.global_admin?
        scope.all
      elsif (event = Current.event)
        user_roles = user.event_role_assignments.where(event: event).pluck(:role)
        if user_roles.intersect?(%w[event_admin ops limited safeguarding_lead read_only])
          scope.joins(:participant_event).where(participant_events: { event_id: event.id })
        elsif user.participant
          scope.joins(:participant_event).where(participant_events: { event_id: event.id, participant_id: user.participant.id })
        elsif user.guardian
          scope.joins(:participant_event).where(participant_events: { event_id: event.id, id: user.guardian.participant_event_ids })
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

    return true if has_any_event_role?
    return true if owns_record?
    return true if guardian_of_participant?

    false
  end

  def can_edit?
    return true if user.global_admin?
    return false unless event

    return true if has_role?("event_admin")
    return true if owns_record?
    return true if guardian_of_participant?

    false
  end

  def owns_record?
    user.participant && record.participant_event&.participant_id == user.participant.id
  end

  def guardian_of_participant?
    user.guardian && user.guardian.participant_event_ids.include?(record.participant_event_id)
  end

  def event
    record.participant_event&.event
  end

  def has_any_event_role?
    return false unless event

    user.event_role_assignments.exists?(event: event)
  end

  def has_role?(*roles)
    return false unless event

    user.event_role_assignments.exists?(event: event, role: roles)
  end
end
