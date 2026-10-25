# frozen_string_literal: true

require 'test_helper'

class TrainingAssignmentTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @manager = User.create!(tenant: @tenant, email: 'training-manager@example.com', role: 'admin', password: 'password123')
    @staff = User.create!(tenant: @tenant, email: 'training-staff@example.com', role: 'employee', password: 'password123')
    @other = User.create!(tenant: @tenant, email: 'training-other@example.com', role: 'employee', password: 'password123')
    @module = TrainingModule.create!(title: 'Opening the store', body: 'Unlock, lights, register.')
  end

  teardown { Current.reset }

  def assign(person = @staff, due_on: Date.current + 7)
    TrainingAssignment.assign!(@module, [person], due_on: due_on, actor: @manager).first.first
  end

  test 'assigning writes the assignment and its first history row, and skips an open duplicate' do
    assignment = assign
    assert_equal 'assigned', assignment.status
    assert_equal @manager, assignment.assigned_by
    event = assignment.events.sole
    assert_equal ['assigned', nil, 'assigned', 1, @manager.id], [event.action, event.from_status, event.to_status, event.module_revision, event.actor_id]

    created, skipped = TrainingAssignment.assign!(@module, [@staff, @other], due_on: nil, actor: @manager)
    assert_equal [@other], created.map(&:assignee)
    assert_equal [@staff], skipped
  end

  test 'assigned to in progress to completed records actor, time and module revision' do
    assignment = assign
    assignment.transition!('start', actor: @staff)
    assert_equal 'in_progress', assignment.status
    assert assignment.started_at
    @module.update!(body: 'Changed text')
    assert_equal 2, @module.reload.revision
    assignment.transition!('complete', actor: @staff)
    assignment.reload
    assert_equal ['completed', @staff.id, 2], [assignment.status, assignment.completed_by_id, assignment.completed_revision]
    assert assignment.completed_at
    assert_equal %w[assigned started completed], assignment.events.map(&:action)
    assert_equal [nil, 'assigned', 'in_progress'], assignment.events.map(&:from_status)
  end

  test 'invalid transitions are refused and leave no history' do
    assignment = assign
    assert_raises(TrainingAssignment::TransitionRefused) { assignment.transition!('complete', actor: @staff) } # must start first
    assert_raises(TrainingAssignment::TransitionRefused) { assignment.transition!('start', actor: @other) }   # not theirs
    assert_raises(TrainingAssignment::TransitionRefused) { assignment.transition!('start', actor: @manager) } # managers do not train for staff
    assert_raises(TrainingAssignment::TransitionRefused) { assignment.transition!('cancel', actor: @staff) }  # staff cannot cancel
    assert_raises(TrainingAssignment::TransitionRefused) { assignment.transition!('approve', actor: @manager) }
    assignment.transition!('start', actor: @staff)
    assignment.transition!('complete', actor: @staff)
    assert_raises(TrainingAssignment::TransitionRefused) { assignment.transition!('start', actor: @staff) }
    assert_raises(TrainingAssignment::TransitionRefused) { assignment.transition!('cancel', actor: @manager) }
    assert_equal 3, assignment.events.count

    cancelled = assign(@other)
    cancelled.transition!('cancel', actor: @manager, note: 'Wrong person')
    assert_equal 'Wrong person', cancelled.events.last.note
    assert_raises(TrainingAssignment::TransitionRefused) { cancelled.transition!('start', actor: @other) }
  end

  test 'status cannot be set directly and assignments cannot be destroyed' do
    assignment = assign
    assignment.status = 'completed'
    assert_not assignment.save
    assert_includes assignment.errors[:status], 'changes only through a training action'
    assert_not assignment.reload.destroy
    assert TrainingAssignment.exists?(assignment.id)
  end

  test 'history is append-only' do
    event = assign.events.sole
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(actor_name: 'Someone else') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.delete }
    assert_not event.destroy
    assert_equal 'assigned', TrainingAssignmentEvent.find(event.id).action
  end

  test 'assignees, modules and history stay in their own workspace' do
    other_tenant = Tenant.create!(name: 'Elsewhere', subdomain: "train#{SecureRandom.hex(3)}")
    outsider = User.create!(tenant: other_tenant, email: 'outsider-train@example.com', role: 'employee', password: 'password123')
    assignment = TrainingAssignment.new(training_module: @module, assignee: outsider, status: 'assigned')
    assert_not assignment.valid?
    assert assignment.errors[:assignee].any?

    @other.update!(active: false)
    assert_not TrainingAssignment.new(training_module: @module, assignee: @other, status: 'assigned').valid?

    assign
    Current.tenant = other_tenant
    assert_equal 0, TrainingModule.count
    assert_equal 0, TrainingAssignment.count
    assert_equal 0, TrainingAssignmentEvent.count
  end

  test 'video link must be an https link' do
    assert TrainingModule.new(title: 'Video', video_url: 'https://videos.example.com/watch?v=1').valid?
    %w[javascript:alert(1) http://example.com/video ftp://example.com/x not-a-link].each do |url|
      assert_not TrainingModule.new(title: 'Video', video_url: url).valid?, url
    end
  end

  test 'attachments accept the allowed types and sizes only, encrypted at rest' do
    pdf = TrainingAttachment.from_upload(@module, upload('%PDF-1.4 handbook', 'handbook.pdf'), @manager)
    assert pdf.save, pdf.errors.full_messages.to_sentence
    assert_equal '%PDF-1.4 handbook', pdf.reload.bytes
    raw = TrainingAttachment.connection.select_value("SELECT content_base64 FROM training_attachments WHERE id = #{pdf.id}")
    assert_not_includes raw, Base64.strict_encode64('%PDF-1.4 handbook')

    assert_not TrainingAttachment.from_upload(@module, upload('MZ...', 'setup.exe'), @manager).save
    assert_not TrainingAttachment.from_upload(@module, upload('not a pdf', 'fake.pdf'), @manager).save
    video = TrainingAttachment.from_upload(@module, upload("\x00\x00\x00\x18ftypmp42", 'clip.mp4'), @manager)
    assert_not video.save
    assert_match(/Link to a video/, video.errors.full_messages.to_sentence)
    big = TrainingAttachment.from_upload(@module, upload('a' * (TrainingAttachment::MAX_BYTES + 1), 'big.txt'), @manager)
    assert_not big.save

    pdf.remove!(@manager)
    assert_equal 2, @module.reload.revision
    assert_empty @module.attachments
    assert_not pdf.destroy
  end

  private

  def upload(bytes, name)
    Rack::Test::UploadedFile.new(StringIO.new(bytes.b), 'application/octet-stream', original_filename: name)
  end
end
