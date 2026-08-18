# Guards the fix for the stored-XSS reports against participant-controlled
# text (names, preferred names, flight codes, group labels) reaching an admin's
# browser as markup.
#
# Any template literal in our JavaScript that looks like markup and
# interpolates a value must be tagged with the `html` helper from
# app/javascript/utils/html.js — see that file for why. This spec walks the
# sources and fails on an untagged one, so a new `${...}` inside an innerHTML
# template can't quietly reintroduce the hole.
require "spec_helper"

# Finds template literals in JavaScript, distinguishing them from quoted
# strings and comments, and records the tag (if any) and each `${...}`.
module MarkupLiteralScanner
  module_function

  SAFE_TAG = "html"

  # Interpolations whose value can only ever be a string literal carry no
  # caller data into the markup: `${"a"}`, `${cond ? "a" : "b"}`.
  LITERAL = /\A(['"]).*\1\z/m
  LITERAL_TERNARY = /\?\s*(['"])[^'"]*\1\s*:\s*(['"])[^'"]*\2\s*\z/
  LOOKS_LIKE_MARKUP = %r{<\s*/?[a-zA-Z]}

  Literal = Struct.new(:tag, :body, :interpolations, :line, keyword_init: true)

  def violations_in(source)
    literals(source).select do |literal|
      next false unless literal.body.match?(LOOKS_LIKE_MARKUP)
      next false if literal.tag == SAFE_TAG

      literal.interpolations.any? { |expr| !literal_only?(expr) }
    end
  end

  def literal_only?(expr)
    stripped = expr.strip
    stripped.empty? ||
      (stripped.match?(LITERAL) && !stripped.include?("\#{")) ||
      stripped.match?(LITERAL_TERNARY)
  end

  # Character walk rather than a regex: backticks appear inside comments and
  # quoted strings, and `${ ... }` can nest further template literals.
  def literals(source)
    found = []
    open = []
    braces = []
    index = 0

    while index < source.length
      char = source[index]
      in_code = open.empty? || braces.last.to_i.positive?

      if in_code && (skipped = skip_non_code(source, index))
        index = skipped
        next
      end

      case
      when char == "\\"
        index += 2
        next
      when char == "`"
        if open.any? && braces.last.to_i.zero?
          literal = open.pop
          braces.pop
          found << finish(source, literal, index)
        else
          open << { start: index, tag: tag_before(source, index), interpolations: [] }
          braces << 0
        end
      when char == "$" && source[index + 1] == "{" && open.any? && braces.last.to_i.zero?
        finish_index = end_of_interpolation(source, index + 2)
        expression = source[(index + 2)...finish_index]
        open.last[:interpolations] << expression
        # A template literal nested in the interpolation gets judged on its own
        # tag, so `html`<p>${cond ? `<b>${name}</b>` : ""}</p>`` still fails.
        found.concat(nested_literals(source, expression, index + 2))
        index = finish_index + 1
        next
      when open.any? && braces.last.to_i.positive?
        braces[-1] += 1 if char == "{"
        braces[-1] -= 1 if char == "}"
      end

      index += 1
    end

    found
  end

  def nested_literals(source, expression, expression_start)
    offset = source[0...expression_start].count("\n")
    literals(expression).each { |literal| literal.line += offset }
  end

  # Returns the index just past a comment or quoted string starting at `index`,
  # or nil when `index` isn't the start of one.
  def skip_non_code(source, index)
    char = source[index]
    nxt = source[index + 1]

    return source.index("\n", index) || source.length if char == "/" && nxt == "/"
    return (source.index("*/", index) || source.length - 2) + 2 if char == "/" && nxt == "*"
    return unless char == "'" || char == '"'

    cursor = index + 1
    while cursor < source.length && source[cursor] != char && source[cursor] != "\n"
      cursor += source[cursor] == "\\" ? 2 : 1
    end
    cursor + 1
  end

  # Index of the `}` closing an interpolation that starts at `from`.
  def end_of_interpolation(source, from)
    depth = 1
    cursor = from

    while cursor < source.length && depth.positive?
      case source[cursor]
      when "{" then depth += 1
      when "}" then depth -= 1
      when "`" then cursor = end_of_nested_literal(source, cursor)
      end
      cursor += 1
    end

    cursor - 1
  end

  def end_of_nested_literal(source, from)
    cursor = from + 1
    depth = 0

    while cursor < source.length
      break if source[cursor] == "`" && depth.zero?
      depth += 1 if source[cursor] == "$" && source[cursor + 1] == "{"
      depth -= 1 if source[cursor] == "}" && depth.positive?
      cursor += 1
    end

    cursor
  end

  def tag_before(source, index)
    source[0...index].rstrip[/([A-Za-z_$][\w$.]*)\z/, 1]
  end

  def finish(source, literal, index)
    Literal.new(
      tag: literal[:tag],
      body: source[(literal[:start] + 1)...index],
      interpolations: literal[:interpolations],
      line: source[0...literal[:start]].count("\n") + 1
    )
  end
end

RSpec.describe "markup built in JavaScript" do
  root = Pathname.new(File.expand_path("../..", __dir__))

  def self.read_utf8(path)
    path.read(encoding: "UTF-8")
  end

  # Every JS module, plus the inline <script> blocks in ERB views.
  def self.sources(root)
    modules = root.glob("app/javascript/**/*.js")
                  .reject { |path| path.to_s.include?("/vendor/") }
                  .map { |path| [ path.relative_path_from(root).to_s, read_utf8(path), 0 ] }

    inline = root.glob("app/views/**/*.erb").flat_map do |path|
      source = read_utf8(path)
      source.to_enum(:scan, %r{<script\b[^>]*>(.*?)</script>}m).map do
        body = Regexp.last_match(1)
        offset = Regexp.last_match.begin(1)
        [ path.relative_path_from(root).to_s, body, source[0...offset].count("\n") ]
      end
    end

    modules + inline
  end

  sources(root).each do |relative_path, source, line_offset|
    next if source.strip.empty?

    it "escapes every interpolation in #{relative_path}" do
      offenders = MarkupLiteralScanner.violations_in(source).map do |literal|
        "#{relative_path}:#{literal.line + line_offset} — untagged markup template " \
          "interpolating #{literal.interpolations.map(&:strip).reject(&:empty?).first(3).inspect}"
      end

      expect(offenders).to be_empty, <<~MESSAGE
        Markup built from interpolated values must use the `html` tag from
        app/javascript/utils/html.js (or the matching inline helper in
        app/views/admin/scans/scanner.html.erb), which escapes each `${...}`:

        #{offenders.join("\n")}

        If a value really is markup you built yourself, wrap it in `safeMarkup`.
      MESSAGE
    end
  end

  # The scanner is the whole guard, so check it still spots the original bugs.
  describe MarkupLiteralScanner do
    it "flags an untagged template that interpolates a participant's name" do
      source = <<~JS
        const scanHtml = `
          <p class="font-medium text-sm">${data.participant.display_name}</p>
        `
      JS

      expect(described_class.violations_in(source).map(&:interpolations).flatten)
        .to eq([ "data.participant.display_name" ])
    end

    it "accepts the same template once it is tagged" do
      source = <<~JS
        const scanHtml = html`
          <p class="font-medium text-sm">${data.participant.display_name}</p>
        `
      JS

      expect(described_class.violations_in(source)).to be_empty
    end

    it "flags an interpolation nested inside a tagged template" do
      source = <<~JS
        const row = html`<div>${cond ? `<b>${name}</b>` : ""}</div>`
      JS

      expect(described_class.violations_in(source).map(&:interpolations).flatten)
        .to eq([ "name" ])
    end

    it "ignores markup with no interpolation at all" do
      expect(described_class.violations_in('el.innerHTML = "<div>No results found</div>"')).to be_empty
    end

    it "ignores a class-name ternary over string literals" do
      source = 'const row = `<span class="${done ? "bg-green-100" : "bg-gray-100"}">x</span>`'

      expect(described_class.violations_in(source)).to be_empty
    end

    it "ignores template literals that are not markup" do
      expect(described_class.violations_in('el.querySelector(`[data-id="${id}"]`)')).to be_empty
    end

    it "does not mistake a backtick inside a comment or string for a literal" do
      source = <<~JS
        // use `html` for this
        const note = "a ` backtick"
        const safe = html`<p>${name}</p>`
      JS

      expect(described_class.violations_in(source)).to be_empty
    end
  end
end
