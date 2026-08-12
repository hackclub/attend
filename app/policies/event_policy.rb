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

    user.event_role_assignments.exists?(event: record, role: %w[event_admin ops]) ||
      user.series_member_for_event?(record)
  end

  def manage_groups?
    return true if user.global_admin?

    user.event_role_assignments.exists?(event: record, role: %w[event_admin ops]) ||
      user.series_member_for_event?(record)
  end

  def api_participants?
    return true if user.global_admin?

    user.event_role_assignments.exists?(event: record, role: %w[event_admin ops safeguarding_lead]) ||
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
