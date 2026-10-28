# frozen_string_literal: true

require 'test_helper'
require_relative '../support/team_chat_helper'

# The team chat side panel: Rupert pages without the shell, and views a bot builds.
class ChatSidePanelTest < ActionDispatch::IntegrationTest
  include TeamChatHelper

  setup do
    @admin = users(:regular_user)
    post login_path, params: { email: @admin.email, password: 'password' }
  end

  test 'a Rupert page opened in the panel has no shell and sends its links to the full window' do
    get sales_reports_path(panel: 1)
    assert_response :success
    assert_select 'header.app-topbar', 0
    assert_select 'aside#app-rail', 0
    assert_select 'head base[target=_top]'
    assert_select 'body.panel-view[data-turbo=false] main.app-main-panel'
    get sales_reports_path
    assert_select 'header.app-topbar'
    assert_select 'head base', 0
  end

  test 'the chat page has the side panel ready and closed' do
    get team_chat_path
    follow_redirect!
    assert_select 'aside.chat-panel[data-team-chat-target=panel][hidden]'
    assert_select 'aside.chat-panel button[data-action="team-chat#closePanel"]'
  end

  test 'a bot can build a view; it is saved on the reply with its unchecked figures counted' do
    Current.set(tenant: @admin.tenant, user: @admin) do
      room = TeamChat::Room.direct_for(@admin)
      script_model({ tool: 'show_view', arguments: { title: 'Two days', kind: 'table', columns: %w[Day Count], rows: [['Mon', '$12.00'], ['Tue', '$5.00']] } },
        { text: 'Here are the two days side by side.' })
      reply = TeamChat::Post.call(room: room, user: @admin, body: '@rupert show me two days in a table').reply
      TeamChat::Agent.new(reply, config: team_chat_config).run
      view = reply.reload.meta['views'].sole
      assert_equal ['Two days', 'table', 2], [view['title'], view['kind'], view['unchecked']]
      assert_equal [view], reply.as_payload(viewer: @admin)[:views]
    end
  end

  test 'a plot request rejects static HTML and can use an adjustable structured view' do
    Current.set(tenant: @admin.tenant, user: @admin) do
      room = TeamChat::Room.direct_for(@admin)
      script_model({ tool: 'show_view', id: 'view-html', arguments: { title: 'Counts', kind: 'html', html: '<p>10</p>' } },
        { tool: 'show_view', id: 'view-chart', arguments: { title: 'Counts', kind: 'bar_chart', columns: %w[Day Count], rows: [['Mon', 10]] } },
        { text: 'Here is the chart.' })
      reply = TeamChat::Post.call(room: room, user: @admin, body: '@rupert plot the counts').reply
      TeamChat::Agent.new(reply, config: team_chat_config).run
      run = TeamChat::Run.find_by!(message_id: reply.id)
      assert_includes run.tool_results.first['result'], 'use a structured table, bar chart or line chart'
      assert_equal 'bar_chart', reply.reload.meta['views'].sole['kind']
    end
  end
end
