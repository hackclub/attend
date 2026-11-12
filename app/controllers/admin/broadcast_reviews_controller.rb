module Admin
  # Broadcasts BroadcastScreener held back as possible marketing, spam or
  # off-topic. Global admins approve (it goes out) or reject (it goes back to
  # its author) them.
  class BroadcastReviewsController < BaseController
    global_page
    before_action :require_global_admin
    before_action :set_review, only: [ :show, :approve_broadcast, :reject_broadcast ]

    def index
      @pending = BroadcastReview.pending
        .includes(:event, :submitted_by_user, :reviewable)
        .order(:created_at)
      @decided = BroadcastReview.where.not(status: :pending)
        .includes(:event, :submitted_by_user, :decided_by_user)
        .order(decided_at: :desc)
        .limit(50)
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

    private

    def set_review
      @review = BroadcastReview.includes(:event, :reviewable).find(params[:id])
    end

    def require_global_admin
      return if current_user.global_admin?

      redirect_to admin_root_path, alert: "Only global admins can review held messages."
    end
  end
end
