# Admin-only API reference, rendered with Scalar (https://github.com/scalar/scalar).
#
# `index` renders the Scalar single-page reference; `openapi` serves the
# OpenAPI document it reads. Both are gated to admins so the API surface (and
# any example values in the spec) is never exposed publicly.
class DocsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin

  layout false

  def index
  end

  def openapi
    render json: openapi_document
  end

  private

  def require_admin
    return if current_user&.admin?

    redirect_to root_path, alert: "You are not authorized to access the API docs."
  end

  def openapi_document
    @openapi_document ||= YAML.load_file(Rails.root.join("config", "openapi.yml"))
  end
end
