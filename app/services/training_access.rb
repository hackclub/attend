# Who may take which course. Open courses are for anyone signed in; an
# invite-only one is for people invited by hand, plus everyone whose role at
# an event that hasn't finished needs the badge the course awards — staff and
# volunteers are invited by being on the roster. Global admins see every
# course, so they can check one before inviting anybody.
class TrainingAccess
  def initialize(user, now: Time.current)
    @user = user
    @now = now
  end

  def accessible?(course)
    reason(course).present?
  end

  # :admin, :open, :invited, :event, or nil.
  def reason(course)
    if @user.global_admin? then :admin
    elsif course.access_open? then :open
    elsif invited_course_ids.include?(course.id) then :invited
    elsif event_badge_ids.include?(course.training_badge_id) then :event
    end
  end

  def courses(scope = TrainingCourse.published)
    return scope if @user.global_admin?

    scope.where(access: "open")
      .or(scope.where(id: invited_course_ids.to_a))
      .or(scope.where(training_badge_id: event_badge_ids.to_a))
  end

  # The events that invited this person to the course, for saying why.
  def events_for(course)
    return [] if course.badge.nil?

    current_roles_by_event.filter_map do |event, roles|
      event if course.badge.required_for?(roles)
    end
  end

  private

  def invited_course_ids
    @invited_course_ids ||= @user.training_course_invitations.pluck(:training_course_id).to_set
  end

  def event_badge_ids
    @event_badge_ids ||= begin
      roles = current_roles_by_event.values.flatten.uniq
      roles.empty? ? Set.new : TrainingBadge.required_of_any(roles).pluck(:id).to_set
    end
  end

  # { event => [role, ...] } for events that haven't finished. Series owners
  # and organizers count as event admins on every event in their series.
  def current_roles_by_event
    @current_roles_by_event ||= begin
      live = Event.where("events.ends_at IS NULL OR events.ends_at >= ?", @now)
      roles = Hash.new { |hash, key| hash[key] = [] }
      @user.event_role_assignments.joins(:event).merge(live).includes(:event).each { |a| roles[a.event] << a.role }
      @user.event_volunteers.joins(:event).merge(live).includes(:event).each { |v| roles[v.event] << "volunteer" }
      series_ids = @user.series_role_assignments.select(:event_series_id)
      live.where(event_series_id: series_ids).each { |event| roles[event] |= [ "event_admin" ] }
      roles
    end
  end
end
