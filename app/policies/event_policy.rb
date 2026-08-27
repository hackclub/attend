class EventPolicy < ApplicationPolicy
  def index?
    user.global_admin? || user.event_role_assignments.exists? || user.series_role_assignments.exists?
  end

  def show?
    user.global_admin? || user.can_access_event?(record)
  end

  # Series members can create events inside their own series; the record must
  # carry the target event_series_id so membership can be checked here.
  def create?
    return true if user.global_admin?

    record.is_a?(Event) && record.event_series_id.present? && user.series_member_for_event?(record)
  end

  def update?
    user.global_admin? || user.can_access_event?(record)
  end

  def select?
    user.global_admin? || user.can_access_event?(record)
  end

  def regenerate_api_key?
    user.global_admin? || user.event_admin_for?(record)
  end

  def destroy?
    user.global_admin?
  end

  def withdraw?
    user.global_admin?
  end

  def manage_rooming?
    return true if user.global_admin?

    user.event_role_assignments.exists?(event: record, role: %w[event_admin ops limited]) ||
      user.series_member_for_event?(record)
  end

  def manage_groups?
    return true if user.global_admin?

    user.event_role_assignments.exists?(event: record, role: %w[event_admin ops limited]) ||
      user.series_member_for_event?(record)
  end

  # "limited" is included: the controller redacts dates of birth and addresses
  # out of the payload for it (see Api::V1::ParticipantsController#include_pii?).
  # "read_only" still gets nothing.
  def api_participants?
    return true if user.global_admin?

    user.event_role_assignments.exists?(event: record, role: %w[event_admin ops limited safeguarding_lead]) ||
      user.series_member_for_event?(record)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.global_admin?
        scope.all
      else
        scope.where(id: user.event_role_assignments.select(:event_id))
             .or(scope.where(event_series_id: user.series_role_assignments.select(:event_series_id)))
      end
    end
  end
end
