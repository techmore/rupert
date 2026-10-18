# frozen_string_literal: true

module Marketing
  class EmailCampaign < Record
    self.table_name = 'marketing_email_campaigns'
    STATUSES = %w[draft approved sending sent paused failed].freeze
    belongs_to :sender, class_name: 'Marketing::EmailSender'
    has_many :recipients, class_name: 'Marketing::EmailRecipient', foreign_key: :campaign_id, dependent: :destroy

    validates :name, presence: true, length: { maximum: 200 }
    validates :subject, presence: true, length: { maximum: 200 }
    validates :body, presence: true, length: { maximum: 20_000 }
    validates :status, inclusion: { in: STATUSES }
    validate { same_tenant(:sender) }
    validate { errors.add(:subject, 'cannot contain line breaks') if subject.to_s.match?(/[\r\n]/) }
    validate do
      if persisted? && status != 'draft' && (changed & %w[sender_id subject body segment_status segment_source segment_tag]).any?
        errors.add(:base, 'Approved campaigns cannot be edited. Create a new draft instead.')
      end
    end

    def editable?
      status == 'draft'
    end
  end
end
