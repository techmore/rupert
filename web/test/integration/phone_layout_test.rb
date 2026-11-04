# frozen_string_literal: true

require 'test_helper'

# Phone widths and theme-safe colours (docs/audits/2026-11-02-web-app-ux-review.md). Layout is
# CSS, so these tests pin the markup hooks and stylesheet rules the 375px fixes depend on.
class PhoneLayoutTest < ActionDispatch::IntegrationTest
  CSS = Rails.root.join('app/assets/tailwind/application.css')

  setup do
    @admin = users(:regular_user)
    post login_path, params: { email: @admin.email, password: 'password' }
  end

  teardown { Current.reset }

  test 'release utilities step out of the phone top bar and stay reachable from the rail' do
    get inventory_index_path
    assert_response :success
    assert_select "header a.nav-utility.topbar-wide-only[href='#{release_tracker_path}']", 1
    # The four utilities the bar always keeps are not marked wide-only.
    assert_select 'header button.nav-utility[aria-label="Search"]:not(.topbar-wide-only)'
    assert_select 'header button.nav-account:not(.topbar-wide-only)'
    get settings_path
    assert_select "aside#app-rail a[href='#{release_tracker_path}']", text: 'Release blockers'
  end

  test 'the phone rules for the top bar, tables and filters are in the stylesheet' do
    css = File.read(CSS)
    phone = css[/@media\(max-width:640px\) \{\n  \.app-topbar.*?\n\}/m]
    assert phone, 'phone block for the top bar'
    assert_includes phone, '.topbar-wide-only { display:none !important; }'
    assert_match(/@media\(max-width:439px\) \{ \.app-brand-name \{ display:none; \} \}/, css)
    assert_match(/\.report-table-scroll \{ position:relative;overflow-x:auto; \}/, css, 'sr-only header labels stay inside the scroller')
    assert_match(/\.toolbar > \.toolbar-field \{ flex-basis:100%;max-width:none; \}/, css)
  end

  test 'standalone glossary, sort and disclosure targets are at least 24px' do
    css = File.read(CSS)
    assert_match(/\.term-trigger \{[^}]*min-width:24px;min-height:24px/, css)
    assert_match(/\.report-table-sort \{[^}]*min-width:24px;min-height:24px/, css)
    assert_match(/\.explainer-summary \{[^}]*min-height: 24px/m, css)
  end

  test 'the timesheet week arrows keep their size and the week controls wrap' do
    get people_timesheets_path(period: Date.current.beginning_of_week.iso8601)
    assert_response :success
    assert_select 'nav[aria-label="Week"].flex-wrap'
    assert_select 'nav[aria-label="Week"] a.flex-none[title="Previous week"]'
    assert_select 'nav[aria-label="Week"] a.flex-none[title="Next week"]'
    assert_select 'span.bg-olive.text-cream', text: Date.current.day.to_s
  end

  test 'settings lead with business details and pay rules, with the raw environment keys after them' do
    get settings_path
    assert_response :success
    titles = css_select('main .section-card > h2, main .section-card > div > h2, main .section-card h2').map { |h| h.text.strip }
    business = titles.index { |t| t.start_with?('Business settings') }
    pay = titles.index { |t| t.start_with?('Pay rules') }
    env = titles.index { |t| t.start_with?('Environment (.env)') }
    assert business && pay && env, titles.inspect
    assert_operator business, :<, env
    assert_operator pay, :<, env
  end

  test 'the empty Staff list says what a staff record is and where sign-in accounts live' do
    get people_employees_path
    assert_response :success
    assert_select 'td.empty-row', text: /No staff records yet/
    assert_select "td.empty-row a[href='#{users_path}']", text: 'Users'
    get people_employees_path(status: 'terminated')
    assert_select 'td.empty-row', text: /No staff match these filters/
    assert_select "td.empty-row a[href='#{people_employees_path}']", text: 'Clear the filters'
  end

  test 'text on the olive accent uses the theme token, never fixed white' do
    # Olive is light in the Dark appearance, so fixed white text drops below 3:1 there; text-cream flips with it.
    offenders = Dir[Rails.root.join('app/views/**/*.erb')].select do |path|
      File.read(path).match?(/(?:\bbg-olive|aria-pressed:bg-olive)\s+(?:aria-pressed:)?text-white/)
    end
    assert_empty offenders.map { |path| path.delete_prefix("#{Rails.root}/") }
  end
end
