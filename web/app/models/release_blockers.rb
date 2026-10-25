# frozen_string_literal: true

# The release gate (config/release_blockers.yml): items the next release waits on that need an
# outside account or a professional. Read from the file only, never the database or the network,
# and re-read when the file changes so ticking an item off needs no code change.
class ReleaseBlockers
  PATH = Rails.root.join('config/release_blockers.yml')
  REPO_ISSUES_URL = 'https://github.com/techmore/rupert/issues'
  STATUSES = %w[open done].freeze

  Item = Data.define(:id, :title, :needed, :issues, :status) do
    def open? = status == 'open'
    def done? = status == 'done'
    def issue_links = issues.map { |number| [number, "#{REPO_ISSUES_URL}/#{number}"] }
  end

  attr_reader :release, :tracker_issue, :items

  def self.current
    mtime = File.exist?(PATH) ? File.mtime(PATH) : nil
    @current = nil if @current_mtime != mtime
    @current_mtime = mtime
    @current ||= mtime ? load(PATH) : new(release: nil, tracker_issue: nil, items: [])
  end

  def self.load(path)
    data = YAML.safe_load_file(path) || {}
    new(release: data['release'].presence, tracker_issue: data['tracker_issue'],
        items: Array(data['items']).map { |raw| parse_item(raw) })
  end

  def self.parse_item(raw)
    status = raw['status'].to_s
    raise ArgumentError, "release blocker #{raw['id']}: status must be open or done" unless STATUSES.include?(status)

    Item.new(id: raw.fetch('id').to_s, title: raw.fetch('title').to_s, needed: raw['needed'].to_s,
             issues: Array(raw['issues']).map { |number| Integer(number) }, status: status)
  end
  private_class_method :parse_item

  def initialize(release:, tracker_issue:, items:)
    @release = release
    @tracker_issue = tracker_issue
    @items = items
  end

  def open_items = items.select(&:open?)
  def done_items = items.select(&:done?)
  def open_count = open_items.size
  def any_open? = open_count.positive?
  def title = ['Release', release, 'blockers'].compact.join(' ')
  def tracker_url = tracker_issue && "#{REPO_ISSUES_URL}/#{tracker_issue}"

  # Owners (an administrator in their own business) and platform administrators; never staff.
  def self.visible_to?(user)
    return false unless user

    user.super_admin? || (user.admin? && user.tenant_id == Current.tenant_id)
  end
end
