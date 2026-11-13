module Admin
  # Broadcasts BroadcastScreener held back as possible marketing, spam or
  # off-topic. Reviewers approve (it goes out) or reject (it goes back to its
  # author) them: global admins for every event, series owners for events in
  # their series (see BroadcastReviewPolicy).
  class BroadcastReviewsController < BaseController
    global_page
    before_action :require_review_access
    before_action :set_review, only: [ :show, :approve_broadcast, :reject_broadcast ]

    def index
      reviews = policy_scope(BroadcastReview)
      @pending = reviews.pending
        .includes(:event, :submitted_by_user, :reviewable)
        .order(:created_at)
      @decided = reviews.where.not(status: :pending)
        .includes(:event, :submitted_by_user, :decided_by_user)
        .order(decided_at: :desc)
        .limit(50)
      load_recipients if policy(BroadcastReview).manage_recipients?
    end

    def show
    end

    def approve_broadcast
      @review.approve!(current_user, note: params[:decision_note])
      @record = @review
      redirect_to admin_broadcast_reviews_path, notice: "Approved. The #{@review.kind_label.downcase} is on its way."
    rescue BroadcastReview::DecisionError => e
      redirect_to admin_broadcast_review_path(@review), alert: e.message
    end

    def reject_broadcast
      @review.reject!(current_user, note: params[:decision_note])
      @record = @review
      redirect_to admin_broadcast_reviews_path, notice: "Rejected. It won't be sent."
    rescue BroadcastReview::DecisionError => e
      redirect_to admin_broadcast_review_path(@review), alert: e.message
    end

    # Which global admins get the "held for review" email. Series owners get
    # it for their own series regardless.
    def update_review_recipients
      authorize BroadcastReview, :manage_recipients?

      ids = User.where(id: Array(params[:recipient_user_ids]).reject(&:blank?), global_role: "global_admin").pluck(:id)
      Setting.broadcast_review_recipient_user_ids = ids
      @record = Setting.find_by(key: Setting::BROADCAST_REVIEW_RECIPIENT_USER_IDS)

      notice = ids.any? ? "Review emails now go to #{helpers.pluralize(ids.size, 'admin')}." : "Nobody is picked, so review emails go to the default list."
      redirect_to admin_broadcast_reviews_path(anchor: "review-recipients"), notice: notice
    end

    private

    def set_review
      @review = BroadcastReview.includes(:event, :reviewable).find(params[:id])
      authorize @review
    end

    def load_recipients
      @selectable_users = User.where(global_role: "global_admin").order(:name)
      @selected_user_ids = Setting.broadcast_review_recipients.pluck(:id).map(&:to_s)
      @fallback_emails = @selected_user_ids.empty? ? BroadcastReviewMailer.global_reviewer_emails : []
    end

    def require_review_access
      return if policy(BroadcastReview).index?

      redirect_to admin_root_path, alert: "Only global admins and series owners can review held messages."
    end
  end
end
