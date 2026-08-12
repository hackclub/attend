class TicketPolicy < ApplicationPolicy
  def index?
    user.global_admin? || user.support_staff_event_ids.any?
  end

  def show?
    return true if user.global_admin?

    if record.event_id.present?
      record.event_id.in?(user.support_staff_event_ids)
    else
      user.support_inbox_triage_access?
    end
  end

  def update?
    show?
  end

  def close?
    update?
  end

  def reopen?
    update?
  end

  def assign?
    update?
  end

  def set_event?
    update?
  end

  def set_subject?
    update?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.all if user.global_admin?

      staffed = scope.where(event_id: user.support_staff_event_ids)
      if user.support_inbox_triage_access?
        staffed.or(scope.where(event_id: nil))
      else
        staffed
      end
    end
  end
end
