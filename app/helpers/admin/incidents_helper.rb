module Admin::IncidentsHelper
  def render_severity_badge(severity)
    colors = {
      "low" => "bg-green-100 text-green-800",
      "medium" => "bg-yellow-100 text-yellow-800",
      "high" => "bg-orange-100 text-orange-800",
      "critical" => "bg-red-100 text-red-800"
    }
    color_class = colors[severity] || "bg-gray-100 text-gray-800"

    content_tag(:span, severity.humanize, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{color_class}")
  end

  def render_status_badge(status)
    colors = {
      "open" => "bg-blue-100 text-blue-800",
      "in_review" => "bg-yellow-100 text-yellow-800",
      "closed" => "bg-gray-100 text-gray-800"
    }
    color_class = colors[status] || "bg-gray-100 text-gray-800"

    content_tag(:span, status.humanize.titleize, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{color_class}")
  end

  def render_category_badge(category)
    colors = {
      "safeguarding" => "bg-purple-100 text-purple-800",
      "medical" => "bg-pink-100 text-pink-800",
      "behavior" => "bg-indigo-100 text-indigo-800",
      "other" => "bg-gray-100 text-gray-800"
    }
    color_class = colors[category] || "bg-gray-100 text-gray-800"

    content_tag(:span, category.humanize, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{color_class}")
  end
end
