# Letter wording goes out under the Hack Foundation's name and signature, so
# only global admins manage templates, an event's own included.
class VisaLetterTemplatePolicy < ApplicationPolicy
  def index?
    user.global_admin?
  end

  def show?
    user.global_admin?
  end

  def preview?
    show?
  end

  def create?
    user.global_admin?
  end

  def update?
    user.global_admin?
  end

  def destroy?
    user.global_admin?
  end
end
