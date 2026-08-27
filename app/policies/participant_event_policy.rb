# frozen_string_literal: true

class ParticipantEventPolicy < ApplicationPolicy
  def index?
    has_event_role?
  end

  def table?
    has_event_role?
  end

  def show?
    can_view?
  end

  def create?
    user.global_admin? || has_role?("event_admin")
  end

  def update?
    can_edit?
  end

  def destroy?
    user.global_admin? || has_role?("event_admin")
  end

  def withdraw?
    user.global_admin? || has_role?("event_admin")
  end

  # Merging pulls another Participant row's data (possibly from other events)
  # into this one and destroys it, so it stays global-admin-only.
  def merge_duplicate?
    user.global_admin?
  end

  def view_travel?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("event_admin", "ops", "limited", "safeguarding_lead")
  end

  def update_travel?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("event_admin", "ops", "limited")
  end

  def view_accommodation?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("event_admin", "ops", "limited", "safeguarding_lead")
  end

  def update_accommodation?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("event_admin", "ops", "limited")
  end

  def view_medical?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("event_admin", "ops", "limited", "safeguarding_lead")
  end

  def update_medical?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("event_admin", "ops", "limited", "safeguarding_lead")
  end

  def view_safeguarding?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("safeguarding_lead", "event_admin")
  end

  def update_safeguarding?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("safeguarding_lead", "event_admin")
  end

  def view_consents?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("event_admin", "safeguarding_lead", "ops", "limited")
  end

  def reset_waiver?
    user.global_admin? || has_role?("event_admin")
  end

  def view_notes?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("event_admin", "ops", "limited", "safeguarding_lead")
  end

  def resync_external?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("event_admin")
  end

  def manage_guardians?
    return true if user.global_admin?
    return false unless record.event == Current.event
    has_role?("event_admin")
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user

      if user.global_admin?
        scope.all
      elsif (event = Current.event)
        user_roles = user.event_role_assignments.where(event: event).pluck(:role)
        if user_roles.intersect?(%w[event_admin ops limited safeguarding_lead])
          scope.where(event: event)
        elsif user.participant
          scope.where(event: event, participant: user.participant)
        elsif user.guardian
          scope.where(event: event, id: user.guardian.participant_event_ids)
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
    # Owners and guardians can always view their own records
    return true if owns_record?
    return true if guardian_of_participant?
    # Staff can only view within their current event context
    return false unless record.event == Current.event

    has_role?("event_admin", "ops", "limited", "safeguarding_lead")
  end

  def can_edit?
    return true if user.global_admin?
    # Owners can always edit their own records
    return true if owns_record?
    # Staff can only edit within their current event context
    return false unless record.event == Current.event

    has_role?("event_admin", "ops", "limited")
  end

  def owns_record?
    user.participant && record.participant_id == user.participant.id
  end

  def guardian_of_participant?
    user.guardian && user.guardian.participant_event_ids.include?(record.id)
  end

  def has_event_role?
    return true if user.global_admin?

    event = Current.event
    return false unless event

    user.event_role_assignments.exists?(event: event)
  end

  def has_role?(*roles)
    event = Current.event
    return false unless event

    user.event_role_assignments.exists?(event: event, role: roles)
  end
end
