module Admin
  # Hand-made invitations to an invite-only course. Paste any number of email
  # addresses; anyone without an Attend account gets a placeholder that links
  # up when they first sign in.
  class TrainingCourseInvitationsController < BaseController
    include AdminTrainingAuthoring

    MAX_PER_REQUEST = 200

    before_action :set_course

    def create
      emails = params[:emails].to_s.split(/[\s,;]+/).map { |email| email.strip.downcase }.compact_blank.uniq
      valid, invalid = emails.partition { |email| email.match?(URI::MailTo::EMAIL_REGEXP) }

      if valid.empty?
        redirect_to admin_training_course_path(@course, anchor: "invitations"), alert: "Enter at least one valid email address."
        return
      end
      if valid.size > MAX_PER_REQUEST
        redirect_to admin_training_course_path(@course, anchor: "invitations"), alert: "Invite at most #{MAX_PER_REQUEST} people at a time."
        return
      end

      invited = valid.filter_map do |email|
        user = User.find_by(email: email) || User.create!(email: email, name: email.split("@").first.titleize)
        invitation = @course.invitations.find_or_initialize_by(user: user)
        next unless invitation.new_record?

        invitation.update!(invited_by: current_user)
        TrainingMailer.course_invitation(invitation: invitation).deliver_later if @course.published?
        invitation
      end
      @record = invited.last

      notice = "#{helpers.pluralize(invited.size, "person")} invited."
      notice += " #{helpers.pluralize(valid.size - invited.size, "was", plural: "were")} already invited." if invited.size < valid.size
      notice += " Invitation emails go out once the course is published." if invited.any? && !@course.published?
      notice += " Skipped: #{invalid.join(", ")}." if invalid.any?
      redirect_to admin_training_course_path(@course, anchor: "invitations"), notice: notice
    end

    def destroy
      @record = @course.invitations.find(params[:id])
      @record.destroy
      redirect_to admin_training_course_path(@course, anchor: "invitations"),
        notice: "Invitation removed. Progress and any badge they've earned are kept."
    end
  end
end
