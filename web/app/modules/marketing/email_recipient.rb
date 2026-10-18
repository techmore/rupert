# frozen_string_literal: true

module Marketing
  class EmailRecipient < Record
    self.table_name = 'marketing_email_recipients'
    STATUSES = %w[queued sent bounced complained failed skipped].freeze
    belongs_to :campaign, class_name: 'Marketing::EmailCampaign'
    belongs_to :customer, class_name: 'Core::Customer'
    validates :email, presence: true
    validates :status, inclusion: { in: STATUSES }
    validate { same_tenant(:campaign) }
  end
end
