# Applicants see their own applications; staff who can review an event's visa
# letters (EventPolicy#review_visa_letters?) see and act on that event's.
class VisaLetterApplicationPolicy < ApplicationPolicy
  def show?
    owner? || reviewer?
  end

  def review?
    reviewer?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      event = Current.event
      return scope.where(event: event) if event && EventPolicy.new(user, event).review_visa_letters?

      own = scope.where(user: user)
      event ? own.where(event: event) : own
    end
  end

  private

  def owner?
    record.user_id.present? && record.user_id == user.id
  end

  def reviewer?
    EventPolicy.new(user, record.event).review_visa_letters?
  end
end
