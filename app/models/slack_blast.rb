class SlackBlast < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :event
  belongs_to :sent_by_user, class_name: "User"
  has_many :slack_blast_recipients, dependent: :destroy

  enum :status, {
    pending: "pending",
    in_progress: "in_progress",
    completed: "completed",
    failed: "failed"
  }

  validates :message, presence: true

  def update_counts!
    update!(
      sent_count: slack_blast_recipients.where(status: "sent").count,
      failed_count: slack_blast_recipients.where(status: "failed").count
    )
  end

  def message_as_slack
    html_to_slack_markdown(message.to_s)
  end

  def message_as_html
    sanitize_html(message.to_s)
  end

  private

  def html_to_slack_markdown(html)
    return "" if html.blank?

    doc = Nokogiri::HTML.fragment(html)
    convert_node_to_slack(doc).strip
  end

  def convert_node_to_slack(node)
    result = ""

    node.children.each do |child|
      case child.type
      when Nokogiri::XML::Node::TEXT_NODE
        result += child.text
      when Nokogiri::XML::Node::ELEMENT_NODE
        result += convert_element_to_slack(child)
      end
    end

    result
  end

  def convert_element_to_slack(element)
    inner = convert_node_to_slack(element)

    case element.name.downcase
    when "strong", "b"
      "*#{inner.strip}*"
    when "em", "i"
      "_#{inner.strip}_"
    when "s", "strike", "del"
      "~#{inner.strip}~"
    when "code"
      "`#{inner.strip}`"
    when "pre"
      "```\n#{inner.strip}\n```"
    when "a"
      href = element["href"]
      if href.present?
        "<#{href}|#{inner.strip}>"
      else
        inner
      end
    when "br"
      "\n"
    when "p"
      "#{inner.strip}\n\n"
    when "ul"
      convert_list_to_slack(element, ordered: false)
    when "ol"
      convert_list_to_slack(element, ordered: true)
    when "li"
      inner
    when "blockquote"
      inner.strip.lines.map { |line| "> #{line}" }.join
    else
      inner
    end
  end

  def convert_list_to_slack(list_element, ordered:)
    result = ""
    index = 1

    list_element.children.each do |child|
      next unless child.element? && child.name.downcase == "li"

      inner = convert_node_to_slack(child).strip
      if ordered
        result += "#{index}. #{inner}\n"
        index += 1
      else
        result += "• #{inner}\n"
      end
    end

    result + "\n"
  end

  def sanitize_html(html)
    ActionController::Base.helpers.sanitize(
      html,
      tags: %w[p br strong b em i u s strike a ul ol li blockquote code pre],
      attributes: %w[href target]
    )
  end
end
