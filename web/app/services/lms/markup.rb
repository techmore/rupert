# frozen_string_literal: true

# Lesson text → blocks for the view. A deliberately small, safe format that an owner can type in
# a textarea; every character of content is HTML-escaped, so no markup can be injected.
#
#   ## Heading                 h2
#   Plain paragraph            p (blank line between paragraphs)
#   - item / 1. item           bulleted / numbered list
#   **bold**                   strong
#   [[key]] or [[key|shown]]   tap-to-define word from the course glossary
#   > tip: text                callout (kinds: tip, why, never, example, note)
#   | a | b |                  table (first row is the header; cells may hold **bold** and [[terms]])
#   {{diagram:card_flow}}      an inline SVG diagram partial (Lms::Markup::DIAGRAMS)
#   {{contacts}}               the support contacts card (Lms::SupportContacts)
#   {{steps}} … {{/steps}}     numbered step cards: each `- ` line inside is one step
#   ---                        thin rule
#
# Returns an array of [kind, payload]: [:html, safe html] for text, [:diagram, key],
# [:contacts, nil] or [:steps, [safe html, …]] for pieces the view renders with a partial.
class Lms::Markup
  include ERB::Util

  DIAGRAMS = %w[card_flow players fee_split tip_timeline refund_paths dispute_timeline pci_scope when_things_break].freeze
  CALLOUTS = %w[tip why never example note].freeze
  Block = Struct.new(:kind, :payload)

  def self.render(text, glossary: {}) = new(glossary).render(text)

  def initialize(glossary)
    @glossary = glossary || {}
    @used_terms = []
    @term_counter = 0
  end

  attr_reader :used_terms

  def render(text)
    blocks = []
    html = +''
    flush = lambda do
      blocks << Block.new(:html, html.html_safe) if html.present?
      html = +''
    end
    paragraphs = text.to_s.gsub("\r\n", "\n").split(/\n{2,}/)
    i = 0
    while i < paragraphs.size
      chunk = paragraphs[i].strip
      i += 1
      next if chunk.empty?

      if (match = chunk.match(/\A\{\{diagram:([a-z_]+)\}\}\z/))
        flush.call
        blocks << Block.new(:diagram, match[1]) if DIAGRAMS.include?(match[1])
      elsif chunk == '{{contacts}}'
        flush.call
        blocks << Block.new(:contacts, nil)
      elsif chunk.start_with?('{{steps}}')
        flush.call
        body = chunk.delete_prefix('{{steps}}')
        until body.include?('{{/steps}}') || i >= paragraphs.size
          body << "\n\n" << paragraphs[i]
          i += 1
        end
        body = body.sub('{{/steps}}', '')
        steps = body.split(/\n(?=- )/).map(&:strip).reject(&:empty?).map { |line| inline(line.sub(/\A- /, '')) }
        blocks << Block.new(:steps, steps)
      else
        html << block_html(chunk)
      end
    end
    flush.call
    blocks
  end

  private

  def block_html(chunk)
    lines = chunk.split("\n")
    first = lines.first
    if chunk == '---'
      '<hr class="lesson-rule">'
    elsif first.start_with?('## ')
      "<h2 class=\"section-title lesson-heading\">#{inline(first.delete_prefix('## '))}</h2>" +
        (lines.size > 1 ? block_html(lines[1..].join("\n")) : '')
    elsif first.start_with?('- ') && lines.all? { |line| line.start_with?('- ', ' ') }
      "<ul class=\"lesson-list\">#{items(chunk, /\n(?=- )/).map { |item| "<li>#{inline(item.delete_prefix('- '))}</li>" }.join}</ul>"
    elsif first.match?(/\A\d+\. /) && lines.all? { |line| line.match?(/\A(\d+\. | )/) }
      "<ol class=\"lesson-list lesson-list-numbered\">#{items(chunk, /\n(?=\d+\. )/).map { |item| "<li>#{inline(item.sub(/\A\d+\. /, ''))}</li>" }.join}</ol>"
    elsif lines.all? { |line| line.start_with?('|') }
      table(lines)
    elsif (match = first.match(/\A> (?:(#{CALLOUTS.join('|')}):\s*)?(.*)\z/m))
      kind = match[1] || 'note'
      body = ([match[2]] + lines[1..].map { |line| line.sub(/\A> ?/, '') }).join(' ')
      "<aside class=\"lesson-callout lesson-callout-#{kind}\"><p class=\"lesson-callout-kind\">#{callout_label(kind)}</p><p>#{inline(body)}</p></aside>"
    else
      "<p>#{inline(lines.join(' '))}</p>"
    end
  end

  # List items may wrap onto indented continuation lines; join them back into one item each.
  def items(chunk, splitter)
    chunk.split(splitter).map { |item| item.split("\n").map(&:strip).join(' ') }
  end

  def table(lines)
    rows = lines.map { |line| line.strip.delete_prefix('|').delete_suffix('|').split('|').map(&:strip) }
    rows.reject! { |cells| cells.all? { |cell| cell.match?(/\A:?-+:?\z/) } }
    head, *body = rows
    thead = "<thead><tr>#{head.map { |cell| "<th scope=\"col\" class=\"th\">#{inline(cell)}</th>" }.join}</tr></thead>"
    tbody = "<tbody>#{body.map { |cells| "<tr>#{cells.map { |cell| "<td class=\"td\">#{inline(cell)}</td>" }.join}</tr>" }.join}</tbody>"
    "<div class=\"table-region lesson-table\" role=\"region\" tabindex=\"0\"><table class=\"table\">#{thead}#{tbody}</table></div>"
  end

  def callout_label(kind)
    { 'tip' => 'Tip', 'why' => 'Why it matters', 'never' => 'Never', 'example' => 'Example', 'note' => 'Note' }.fetch(kind)
  end

  # Escapes everything, then re-introduces the two inline forms.
  def inline(text)
    escaped = html_escape(text.to_s)
    escaped = escaped.gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>')
    escaped.gsub(/\[\[([a-z0-9_]+)(?:\|([^\]]+))?\]\]/) do
      key = Regexp.last_match(1)
      shown = Regexp.last_match(2)
      term(key, shown)
    end
  end

  def term(key, shown)
    name, definition = @glossary[key]
    label = shown.presence || name || key.tr('_', ' ')
    return label unless name

    @used_terms << key unless @used_terms.include?(key)
    panel_id = "lms-term-#{html_escape(key)}-#{@term_counter += 1}"
    <<~HTML.gsub(/\n\s*/, '')
      <span class="term lesson-term" data-controller="lms-term" data-term="#{html_escape(key)}">
        <button type="button" class="term-label" aria-expanded="false" aria-controls="#{panel_id}" title="What does #{html_escape(name.downcase)} mean?" data-action="lms-term#toggle">#{label} <span class="term-mark" aria-hidden="true">?</span></button>
        <span id="#{panel_id}" class="term-panel" role="note" hidden data-lms-term-target="panel"><span class="term-name">#{html_escape(name)}</span><span class="term-definition">#{html_escape(definition)}</span></span>
      </span>
    HTML
  end
end
