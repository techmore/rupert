# frozen_string_literal: true

# Server-side sorting for a list page's column headings (docs/ui-standards.md
# §5, `sortable_th`). The controller names the columns it allows and how each
# one orders; ?sort= and ?dir= only pick from that list. Anything else falls
# back to the default, so request text never reaches SQL.
#
#   COLUMNS = {
#     'name' => ListSort.column('Name') { |dir| [{ last_name: dir }, { id: dir }] },
#     'created' => ListSort.column('Added', :date) { |dir| { created_at: dir, id: dir } }
#   }.freeze
#   @sort = ListSort.new(COLUMNS, sort: params[:sort], dir: params[:dir], default: %w[created desc])
#   @records = @sort.apply(scope)
#
# The order block gets :asc or :desc. A first click sorts ascending, the next
# descending. Blank values should sort last in both directions; put that in
# the block.
class ListSort
  DIRECTIONS = %w[asc desc].freeze
  KINDS = {
    text: { 'asc' => 'A to Z', 'desc' => 'Z to A' },
    number: { 'asc' => 'low to high', 'desc' => 'high to low' },
    date: { 'asc' => 'oldest first', 'desc' => 'newest first' }
  }.freeze

  Column = Data.define(:label, :phrases, :order)

  # kind words the direction for people (text A to Z, numbers low to high,
  # dates oldest first); phrases: { 'asc' => …, 'desc' => … } overrides it.
  def self.column(label, kind = :text, phrases: nil, &order)
    raise ArgumentError, "unknown sort kind #{kind}" unless KINDS.key?(kind)

    Column.new(label: label, phrases: phrases || KINDS.fetch(kind), order: order)
  end

  attr_reader :key, :dir, :columns

  # aliases map old single-word sort links (?sort=recent) to [column, dir];
  # they apply only when the link carries no dir.
  def initialize(columns, sort:, dir:, default:, aliases: {})
    @columns = columns
    sort = sort.to_s
    dir = dir.to_s
    sort, dir = aliases.fetch(sort) if dir.empty? && aliases.key?(sort)
    default_key, default_dir = default
    if columns.key?(sort)
      @key = sort
      @dir = DIRECTIONS.include?(dir) ? dir : 'asc'
    else
      @key = default_key
      @dir = default_dir
    end
  end

  def apply(relation)
    relation.order(*Array.wrap(columns.fetch(key).order.call(dir.to_sym)))
  end

  def active?(column) = key == column.to_s

  def ascending? = dir == 'asc'

  # Where a heading's link goes: flip the direction of the current column,
  # start any other column ascending.
  def next_dir(column) = active?(column) && ascending? ? 'desc' : 'asc'

  # aria-sort belongs on the one heading the list is sorted by.
  def aria_sort(column)
    return unless active?(column)

    ascending? ? 'ascending' : 'descending'
  end

  def label(column = key) = columns.fetch(column.to_s).label

  # "Name, A to Z": heading link titles.
  def phrase(column = key, direction = dir)
    "#{label(column)}, #{columns.fetch(column.to_s).phrases.fetch(direction)}"
  end

  # "sorted by name, A to Z" for status lines and table captions.
  def summary = "sorted by #{label.downcase}, #{columns.fetch(key).phrases.fetch(dir)}"

  def to_params = { 'sort' => key, 'dir' => dir }
end
