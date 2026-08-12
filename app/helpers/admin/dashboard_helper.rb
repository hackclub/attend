module Admin::DashboardHelper
  def severity_badge_class(severity)
    case severity
    when "critical"
      "bg-red-600 text-white"
    when "high"
      "bg-red-100 text-red-800"
    when "medium"
      "bg-amber-100 text-amber-800"
    when "low"
      "bg-green-100 text-green-800"
    else
      "bg-gray-100 text-gray-800"
    end
  end
end
