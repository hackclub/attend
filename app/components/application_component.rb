# Base class for the component layer. Components are the single place a kit
# primitive's markup is written down: the cs_* (console) and portal_* helpers
# are thin delegates to them, so the hundreds of existing call sites and the
# components can never drift apart.
#
# Components here render with an inline `call` rather than a template so the
# emitted markup is exact (no template whitespace) and can be pinned in specs.
class ApplicationComponent < ViewComponent::Base
  private

  # Joins class fragments, dropping nils and blanks: the kit class first, then
  # modifiers, then whatever the caller passed.
  def class_list(*parts)
    parts.flatten.compact_blank.join(" ")
  end
end
