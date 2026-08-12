class EventSeriesPolicy < ApplicationPolicy
  def index?
    user.global_admin? || user.series_role_assignments.exists?
  end

  def show?
    user.global_admin? || user.series_member_for?(record)
  end

  # Series themselves are handed out by global admins; series owners manage
  # everything within.
  def create?
    user.global_admin?
  end

  def update?
    user.series_owner_for?(record)
  end

  def manage_members?
    user.series_owner_for?(record)
  end

  def destroy?
    user.global_admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.global_admin?
        scope.all
      else
        scope.where(id: user.series_role_assignments.select(:event_series_id))
      end
    end
  end
end
