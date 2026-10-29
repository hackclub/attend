module Admin
  # How an event takes visa letter applications: whether it does at all,
  # the public form's deadline, and the reasons reviewers pick from when
  # they reject one.
  class VisaLetterSettingsController < BaseController
    before_action :set_event
    before_action :require_event_selected
    before_action { authorize @event, :review_visa_letters? }

    def edit
      @rejection_reasons_text = @event.visa_letter_rejection_reasons_list.join("\n")
    end

    def update
      @record = @event
      @event.assign_attributes(
        visa_letters: settings_params[:visa_letters],
        visa_letter_deadline: settings_params[:visa_letter_deadline].presence,
        visa_letter_rejection_reasons: settings_params[:visa_letter_rejection_reasons].to_s.lines.map(&:strip).compact_blank.uniq
      )

      if @event.save
        redirect_to admin_event_visa_letters_path(@event), notice: "Visa letter settings saved."
      else
        @rejection_reasons_text = settings_params[:visa_letter_rejection_reasons].to_s
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_event
      @event = Event.find_by!(slug: params[:event_slug])
    end

    def settings_params
      params.require(:event).permit(:visa_letters, :visa_letter_deadline, :visa_letter_rejection_reasons)
    end
  end
end
