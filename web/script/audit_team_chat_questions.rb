# frozen_string_literal: true

# Static inventory only: does not call models or any business tools.
require 'yaml'
require 'json'
root = File.expand_path('..', __dir__)
files = Dir[File.join(root, 'config/team_chat/question_bank/*.yml')].sort
questions = files.flat_map { |path| YAML.safe_load_file(path).fetch('questions') }
normalize = ->(s) { s.to_s.strip.downcase.gsub(/\s+/, ' ') }
answer = ->(v) { { true => 'yes', false => 'no' }.fetch(v, v.to_s) }
by_question = questions.group_by { |q| normalize.call(q['question']) }
duplicates = by_question.select { |_, entries| entries.size > 1 }
conflicts = duplicates.filter_map do |question, entries|
  labels = entries.map { |q| answer.call(q['answerable']) }.uniq
  { question: question, ids: entries.map { |q| q['id'] }, labels: labels } if labels.size > 1
end
sets = Dir[File.join(root, 'config/team_chat/battery*.yml')].sort.to_h do |path|
  entries = YAML.safe_load_file(path).fetch('questions')
  [File.basename(path), { questions: entries.size, without_checks: entries.count { |q| Array(q['checks']).empty? },
    without_expectation: entries.count { |q| q['expect'].to_s.strip.empty? },
    without_reference_or_expectation: entries.count { |q| Array(q['checks']).empty? && q['expect'].to_s.strip.empty? },
    duplicate_ids: entries.group_by { |q| q['id'] }.select { |_, rows| rows.size > 1 }.keys }]
end
puts JSON.pretty_generate({ questions: questions.size, files: files.size,
  labels: questions.group_by { |q| answer.call(q['answerable']) }.transform_values(&:size),
  duplicate_ids: questions.group_by { |q| q['id'] }.select { |_, rows| rows.size > 1 }.keys,
  duplicate_normalized_questions: duplicates.size, conflicting_answerability: conflicts, fixed_sets: sets })
