# frozen_string_literal: true

# Who to call when payments break: workspace configuration shown inside the course (hr.write).
class Lms::Admin::SupportContactsController < Lms::BaseController
  before_action -> { authorize(:module, :hr_write?) }

  def edit
    @contacts = Lms::SupportContacts.for_tenant
  end

  def update
    allowed = Lms::SupportContacts::DEFAULTS.map { |contact| { contact[:key] => %i[phone hours notes] } }
    Lms::SupportContacts.save!(params.fetch(:contacts, {}).permit(*allowed).to_h)
    ActivityLogger.log('lms_support_contacts_updated')
    redirect_to lms_admin_courses_path, notice: t('lms.admin.contacts_saved')
  end
end
