class RegistrationChangeRequestPolicy < ApplicationPolicy
  def create?
    attendee_owner?
  end

  def show?
    attendee_owner? || staff_can_view?
  end

  def approve?
    staff_can_view?
  end

  def request_follow_up?
    staff_can_view?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if (event = Current.event)
        audiences = permitted_audiences(event)
        return scope.joins(:participant_event)
          .where(participant_events: { event_id: event.id }, staff_audience: audiences) if audiences.any?
      end

      return scope.all if user.global_admin?

      return scope.none unless user.participant

      scope.joins(:participant_event)
        .where(participant_events: { participant_id: user.participant.id })
    end

    private

    def permitted_audiences(event)
      return RegistrationChangeRequest.staff_audiences.keys if user.global_admin? || user.event_admin_for?(event)

      audiences = []
      audiences << "operations" if user.ops_for?(event)
      audiences << "safeguarding" if user.safeguarding_lead_for?(event)
      audiences
    end
  end

  private

  def attendee_owner?
    user.participant.present? &&
      record.participant_event.participant_id == user.participant.id &&
      record.requested_by_id == user.id
  end

  def staff_can_view?
    return true if user.global_admin?

    event = record.participant_event.event
    return true if user.event_admin_for?(event)
    return user.ops_for?(event) if record.audience_operations?
    return user.safeguarding_lead_for?(event) if record.audience_safeguarding?

    false
  end
end
