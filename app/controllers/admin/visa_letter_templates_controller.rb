module Admin
  # The wording of visa invitation letters: one global default, and an
  # event's own where it needs different wording. Global admins only, since
  # letters go out under the Hack Foundation's name and signature.
  class VisaLetterTemplatesController < BaseController
    before_action :set_template, only: %i[edit update destroy preview]
    before_action { authorize(@template || VisaLetterTemplate) }

    def index
      @templates = VisaLetterTemplate.includes(:event).order(is_default: :desc, created_at: :desc)
    end

    def new
      @template = VisaLetterTemplate.new(body: VisaLetterTemplate::STARTER_BODY, is_default: VisaLetterTemplate.default_template.nil?)
    end

    def create
      @template = VisaLetterTemplate.new(template_params)

      if @template.save
        @record = @template
        redirect_to admin_visa_letter_templates_path, notice: "#{@template.name} added."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @template.update(template_params)
        @record = @template
        redirect_to admin_visa_letter_templates_path, notice: "#{@template.name} saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @record = @template
      @template.destroy!
      redirect_to admin_visa_letter_templates_path, notice: "#{@template.name} removed."
    end

    # The letter for a made-up applicant, opened in the browser.
    def preview
      send_data @template.preview_pdf, filename: "visa-letter-preview.pdf", type: "application/pdf", disposition: "inline"
    end

    private

    def set_template
      @template = VisaLetterTemplate.find(params[:id])
    end

    def template_params
      params.require(:visa_letter_template).permit(:name, :event_id, :signatory_name, :signatory_title, :body,
        :is_default, :active, :signature_image)
    end
  end
end
