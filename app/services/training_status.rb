# Whether the people working an event hold the training their place requires.
# Badges name the roles that need them (TrainingBadge#required_roles); this
# matches those against each person's roles and their current awards, in a
# fixed number of queries however long the roster is.
#
#   status = TrainingStatus.for_event(event)
#   status.for(user).state  # => :trained, :expiring, :untrained or :not_required
class TrainingStatus
  Result = Data.define(:required, :missing, :lapsed, :expiring, :awards) do
    def state
      if required.empty? then :not_required
      elsif missing.any? then :untrained
      elsif expiring.any? then :expiring
      else :trained
      end
    end

    def trained?
      %i[trained expiring not_required].include?(state)
    end

    # The award that covers a required badge, for its expiry date.
    def award_for(badge)
      awards.find { |award| award.training_badge_id == badge.id }
    end
  end

  NOT_REQUIRED = Result.new(required: [], missing: [], lapsed: [], expiring: [], awards: [])

  # Staff by their event roles, and volunteers as "volunteer".
  def self.for_event(event)
    roles = Hash.new { |hash, key| hash[key] = [] }
    event.event_role_assignments.pluck(:user_id, :role).each { |user_id, role| roles[user_id] << role }
    event.event_volunteers.pluck(:user_id).each { |user_id| roles[user_id] << "volunteer" }
    new(roles)
  end

  def self.for_user_at_event(user, event)
    roles = user.event_role_assignments.where(event: event).pluck(:role)
    roles << "volunteer" if event.event_volunteers.exists?(user: user)
    new({ user.id => roles }).for(user)
  end

  # roles_by_user_id: { user_id => [role, ...] }
  def initialize(roles_by_user_id, now: Time.current)
    @roles_by_user_id = roles_by_user_id
    @now = now
  end

  def for(user)
    results[user.is_a?(User) ? user.id : user] || NOT_REQUIRED
  end

  def summary
    states = results.values.map(&:state)
    {
      required: states.count { |state| state != :not_required },
      untrained: states.count(:untrained),
      expiring: states.count(:expiring)
    }
  end

  private

  def results
    @results ||= begin
      all_roles = @roles_by_user_id.values.flatten.uniq
      badges = all_roles.empty? ? [] : TrainingBadge.where("required_roles && ARRAY[?]::varchar[]", all_roles).ordered.to_a
      awards = badges.empty? ? [] : TrainingBadgeAward.unrevoked.includes(:badge)
        .where(user_id: @roles_by_user_id.keys, training_badge_id: badges.map(&:id))
        .order(:expires_at).to_a
      awards_by_user = awards.group_by(&:user_id)

      @roles_by_user_id.to_h do |user_id, roles|
        required = badges.select { |badge| (badge.required_roles & roles).any? }
        held = awards_by_user.fetch(user_id, [])
        current = required.filter_map { |badge| best_award(held, badge) { |award| award.current?(@now) } }
        missing = required.reject { |badge| current.any? { |award| award.training_badge_id == badge.id } }
        lapsed = missing.select { |badge| held.any? { |award| award.training_badge_id == badge.id } }
        expiring = required.select { |badge| current.any? { |award| award.training_badge_id == badge.id && award.expiring_soon?(@now) } }

        [ user_id, Result.new(required: required, missing: missing, lapsed: lapsed, expiring: expiring, awards: current) ]
      end
    end
  end

  # The longest-lasting current award for a badge: a never-expiring one beats
  # any dated one.
  def best_award(held, badge)
    held.select { |award| award.training_badge_id == badge.id && yield(award) }
      .max_by { |award| award.expires_at || Time.zone.local(9999) }
  end
end
