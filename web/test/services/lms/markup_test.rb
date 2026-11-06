# frozen_string_literal: true

require 'test_helper'

class Lms::MarkupTest < ActiveSupport::TestCase
  GLOSSARY = { 'batch' => ['Batch', 'The day’s sales bundled together.'] }.freeze

  def html(text) = Lms::Markup.render(text, glossary: GLOSSARY).select { |block| block.kind == :html }.map(&:payload).join

  test 'escapes html in every position' do
    out = html("<script>alert(1)</script> **<b>bold</b>**\n\n- <i>item</i>\n\n> tip: <u>x</u>\n\n| <a> | b |\n| c | d |")
    refute_includes out, '<script>'
    refute_includes out, '<b>'
    refute_includes out, '<i>'
    refute_includes out, '<u>'
    refute_includes out, '<a>'
    assert_includes out, '&lt;script&gt;'
    assert_includes out, '<strong>&lt;b&gt;bold&lt;/b&gt;</strong>'
  end

  test 'renders headings, lists, callouts, tables and rules' do
    out = html("## Heading\n\nPara one\nline two\n\n- a\n- b\n\n1. x\n2. y\n\n> never: do not\n\n| H1 | H2 |\n| --- | --- |\n| c1 | c2 |\n\n---")
    assert_includes out, '<h2 class="section-title lesson-heading">Heading</h2>'
    assert_includes out, '<p>Para one line two</p>'
    assert_includes out, '<ul class="lesson-list"><li>a</li><li>b</li></ul>'
    assert_includes html("- one line\n  wraps here\n- two"), '<ul class="lesson-list"><li>one line wraps here</li><li>two</li></ul>'
    assert_includes out, '<ol class="lesson-list lesson-list-numbered"><li>x</li><li>y</li></ol>'
    assert_includes out, 'lesson-callout-never'
    assert_includes out, '<th scope="col" class="th">H1</th>'
    assert_includes out, '<td class="td">c2</td>'
    refute_includes out, '---'
    assert_includes out, '<hr class="lesson-rule">'
  end

  test 'glossary terms become define popovers and unknown keys fall back to text' do
    renderer = Lms::Markup.new(GLOSSARY)
    out = renderer.render('Close the [[batch]] and the [[batch|day’s batch]]; [[nothing]] here.').first.payload
    assert_includes out, 'class="term lesson-term"'
    assert_includes out, '<button type="button" class="term-label" aria-expanded="false"'
    refute_includes out, '<details'
    assert_includes out, 'day’s batch'
    assert_includes out, 'The day’s sales bundled together.'
    assert_includes out, 'nothing here'
    assert_equal ['batch'], renderer.used_terms
  end

  test 'diagram, contacts and steps become their own blocks' do
    blocks = Lms::Markup.render("Intro\n\n{{diagram:card_flow}}\n\n{{diagram:not_real}}\n\n{{contacts}}\n\n{{steps}}\n- First **one**\n- Second [[batch]]\n{{/steps}}\n\nOutro")
    assert_equal %i[html diagram contacts steps html], blocks.map(&:kind)
    assert_equal 'card_flow', blocks[1].payload
    assert_equal 2, blocks[3].payload.size
    assert_includes blocks[3].payload.first, '<strong>one</strong>'
  end

  test 'every shipped lesson renders and only references known diagrams and terms' do
    data = YAML.safe_load_file(Lms::Seeder.files.first)
    glossary = data['glossary'].to_h { |term| [term['key'], [term['term'], term['definition']]] }
    data['lessons'].each do |lesson|
      renderer = Lms::Markup.new(glossary)
      blocks = renderer.render(lesson['body'])
      assert blocks.any?, lesson['slug']
      lesson['body'].scan(/\[\[([a-z0-9_]+)/).flatten.uniq.each { |key| assert glossary.key?(key), "#{lesson['slug']} uses unknown term #{key}" }
      lesson['body'].scan(/\{\{diagram:([a-z_]+)\}\}/).flatten.each { |key| assert_includes Lms::Markup::DIAGRAMS, key }
      assert_includes Lms::Markup::DIAGRAMS, lesson['diagram'] if lesson['diagram']
    end
  end
end
