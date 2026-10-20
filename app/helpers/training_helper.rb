module TrainingHelper
  LESSON_TAGS = %w[
    p br hr h1 h2 h3 h4 strong em b i u s del blockquote code pre
    ul ol li a img table thead tbody tr th td sup sub
  ].freeze
  LESSON_ATTRIBUTES = %w[href src alt title].freeze

  # Lesson bodies are markdown written by global admins. Sanitized anyway,
  # so a pasted <script> or <iframe> can't ride along into every learner's
  # browser; embeds go through TrainingLesson#video_url instead.
  def training_markdown(text)
    return "".html_safe if text.blank?

    html = Kramdown::Document.new(text, auto_ids: false, html_to_native: false).to_html
    sanitize(html, tags: LESSON_TAGS, attributes: LESSON_ATTRIBUTES)
  end

  # The learner nav shows Training to anyone who might need it: staff,
  # volunteers, and anyone who has started a course. Participants don't.
  def training_nav_visible?
    return false unless user_signed_in?
    return @training_nav_visible if defined?(@training_nav_visible)

    @training_nav_visible = TrainingCourse.published.exists? &&
      (current_user.admin? || current_user.event_role_assignments.exists? ||
        current_user.event_volunteers.exists? || current_user.training_course_invitations.exists? ||
        current_user.training_enrollments.exists?)
  end

  # Events whose roster gave the signed-in person access to an invite-only course.
  def training_access_events(course)
    TrainingAccess.new(current_user).events_for(course)
  end

  # Where a lesson's video length comes from, for the lesson form.
  def training_video_length_hint(lesson)
    if lesson.video_source == :youtube && !TrainingVideoLength.youtube_configured?
      "No YouTube API key is configured, so this isn't looked up automatically. Play the video once in the course preview, or enter its length here."
    else
      "Looked up automatically from YouTube and Vimeo links when you save, and read from uploads where possible. You can also play the video once in the course preview, or enter its length here."
    end
  end

  def training_validity(badge)
    return "Never expires" unless badge.expires?

    months = badge.validity_months
    months % 12 == 0 ? "Valid for #{pluralize(months / 12, "year")}" : "Valid for #{pluralize(months, "month")}"
  end

  # A one-word state for an award, for both the learner's badge list and the
  # admin's holder tables.
  def training_award_state(award)
    if award.revoked? then :revoked
    elsif award.expired? then :expired
    elsif award.expiring_soon? then :expiring
    else :current
    end
  end

  def training_award_state_label(award)
    case training_award_state(award)
    when :revoked then "Revoked"
    when :expired then "Expired #{award.expires_at.to_date.to_fs(:long)}"
    when :expiring then "Expires #{award.expires_at.to_date.to_fs(:long)}"
    else award.expires_at ? "Valid until #{award.expires_at.to_date.to_fs(:long)}" : "Valid"
    end
  end

  # The trained/untrained flag for one person on an event roster.
  # `status` is a TrainingStatus::Result.
  def training_status_flag(status)
    missing = status.missing.map(&:name).to_sentence
    case status.state
    when :not_required
      console_ui? ? tag.span("Not required", class: "cs-small cs-muted") : tag.span("Not required", class: "text-xs text-gray-400")
    when :trained
      training_flag(:success, "Trained", title: status.awards.map { |a| "#{a.badge.name}: #{training_award_state_label(a)}" }.join("\n"))
    when :expiring
      training_flag(:warning, "Renewal due", title: "#{status.expiring.map(&:name).to_sentence} expiring within #{TrainingBadge::RENEWAL_WINDOW.inspect}")
    else
      label = status.lapsed.any? && status.lapsed.size == status.missing.size ? "Training expired" : "Not trained"
      training_flag(:error, label, title: "Missing: #{missing}")
    end
  end

  private

  def training_flag(type, label, title:)
    if console_ui?
      tag.span(cs_status(type, label), title: title)
    else
      colors = { success: "bg-green-100 text-green-800", warning: "bg-amber-100 text-amber-800", error: "bg-red-100 text-red-800" }
      tag.span(label, title: title, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{colors.fetch(type)}")
    end
  end
end
