module Admin
  # The Hack Club Safety Team's review of criminal-record declarations.
  # Global admins only; opening one is audit-logged, and so is each review.
  class TrainingDisclosuresController < BaseController
    include AdminTrainingAuthoring

    FILTERS = %w[pending reviewed all].freeze

    def index
      @filter = FILTERS.include?(params[:status]) ? params[:status] : "pending"
      scope = TrainingDisclosure.where.not(review_status: "not_required").includes(:user, :course, :reviewed_by).newest_first
      @disclosures = case @filter
      when "pending" then scope.review_pending
      when "reviewed" then scope.where(review_status: %w[cleared upheld])
      else scope
      end
    end

    def show
      @disclosure = TrainingDisclosure.includes(:user, :course, :reviewed_by).find(params[:id])
      @history = @disclosure.user.training_disclosures.includes(:course).newest_first.where.not(id: @disclosure.id)
      AuditLog.log!(action: :view, record: @disclosure, actor: current_user, metadata: { what: "training_disclosure" })
    end

    def update
      @disclosure = TrainingDisclosure.find(params[:id])
      outcome = params[:outcome].to_s
      unless %w[cleared upheld].include?(outcome) && @disclosure.answered_yes?
        redirect_to admin_training_disclosure_path(@disclosure), alert: "Choose whether to clear or uphold it."
        return
      end

      @disclosure.review!(outcome: outcome, by: current_user, note: params[:note])
      @record = @disclosure
      redirect_to admin_training_disclosures_path,
        notice: outcome == "cleared" ? "Cleared. They can carry on with their training." : "Upheld. They stay ineligible to work events."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_training_disclosure_path(@disclosure), alert: e.record.errors.full_messages.to_sentence
    end
  end
end
