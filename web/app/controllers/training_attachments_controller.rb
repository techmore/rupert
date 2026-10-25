# frozen_string_literal: true

# Files on a training module. Download needs hr.read (staff download through their own assignment instead);
# adding and removing needs hr.write. Removing keeps the bytes for the history and raises the module's revision.
class TrainingAttachmentsController < AuthenticatedController
  before_action -> { response.headers['Cache-Control'] = 'no-store' }
  before_action :set_module

  def show
    authorize(:module, :hr_read?)
    file = @module.attachments.find(params[:id])
    send_data(file.bytes, filename: file.filename, type: file.content_type, disposition: 'attachment')
  end

  def create
    authorize(:module, :hr_write?)
    upload = params[:file]
    return redirect_to(files_path, alert: 'Choose a file to add.') unless upload.respond_to?(:read)

    file = TrainingAttachment.from_upload(@module, upload, Current.user)
    if file.save
      @module.bump_revision!
      ActivityLogger.log('training_file_added', subject: @module, details: "#{file.filename} · revision #{@module.revision}")
      redirect_to files_path, notice: 'File added.'
    else
      redirect_to files_path, alert: file.errors.full_messages.to_sentence
    end
  end

  def destroy
    authorize(:module, :hr_write?)
    file = @module.attachments.find(params[:id])
    file.remove!(Current.user)
    ActivityLogger.log('training_file_removed', subject: @module, details: "#{file.filename} · revision #{@module.reload.revision}")
    redirect_to files_path, notice: 'File removed.'
  end

  private

  def set_module
    @module = TrainingModule.find_by!(tenant_id: Current.tenant_id, id: params[:training_module_id])
  end

  def files_path
    training_module_path(@module, anchor: 'files')
  end
end
