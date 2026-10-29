# frozen_string_literal: true

# Clickable column headings for lists sorted on the server by ListSort
# (docs/ui-standards.md §5). The link keeps every other query parameter
# (filters, search) and drops the page, so a new sort starts at page one.
#
#   <%= sortable_th @sort, 'name' %>
#   <%= sortable_th @sort, 'lifetime', class: 'num' %>
module ListSortHelper
  def sortable_th(sort, column, label = nil, **options)
    column = column.to_s
    label ||= sort.label(column)
    next_dir = sort.next_dir(column)
    query = request.query_parameters.except('page').merge('sort' => column, 'dir' => next_dir)
    icon = { 'ascending' => '▲', 'descending' => '▼' }.fetch(sort.aria_sort(column), '↕')

    tag.th(scope: 'col', class: ['th', 'th-sortable', options.delete(:class)], aria: { sort: sort.aria_sort(column) }, **options) do
      link_to("#{request.path}?#{query.to_query}", class: 'th-sort', title: "Sort by #{sort.phrase(column, next_dir)}", data: { turbo_action: 'advance' }) do
        safe_join([label, tag.span(icon, class: 'th-sort-icon', aria: { hidden: true })])
      end
    end
  end
end
