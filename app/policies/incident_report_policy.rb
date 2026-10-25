# Reports to HQ are confidential: only global admins read, comment on, or
# configure them. Organizers see at most the status of a report they escalated,
# and that goes through IncidentPolicy on the incident side.
class IncidentReportPolicy < ApplicationPolicy
  def index?
    global_admin?
  end

  def show?
    global_admin?
  end

  def comment?
    global_admin?
  end

  def manage_settings?
    global_admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user&.global_admin? ? scope.all : scope.none
    end
  end

  private

  def global_admin?
    user&.global_admin?
  end
end
