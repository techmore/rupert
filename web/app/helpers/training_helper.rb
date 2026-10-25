# frozen_string_literal: true

# Status words and links for training modules and assignments (TrainingAssignment).
module TrainingHelper
  TRAINING_PILLS = { 'assigned' => 'pill-clay', 'in_progress' => 'pill-olive', 'completed' => 'pill-fern', 'cancelled' => 'pill-taupe' }.freeze

  def training_status_pill(assignment)
    return tag.span('Overdue', class: 'pill-rose') if assignment.overdue?

    tag.span(assignment.status_label, class: TRAINING_PILLS.fetch(assignment.status, 'pill-taupe'))
  end

  def training_due(assignment)
    assignment.due_on ? "Due #{assignment.due_on.strftime('%b %-d, %Y')}" : 'No due date'
  end

  # The video opens on its own site; nothing is embedded.
  def training_video_link(training_module)
    return if training_module.video_url.blank?

    link_to('Open video', training_module.video_url, class: 'btn-ghost btn-sm', target: '_blank', rel: 'noopener noreferrer nofollow',
      referrerpolicy: 'no-referrer')
  end
end
