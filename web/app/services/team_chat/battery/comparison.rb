# frozen_string_literal: true

module TeamChat
  class Battery
    # Compare only runs tied to one captured evidence cohort. Each difference
    # is paired by question ID; missing grades are reported, never imputed.
    class Comparison
      class Error < StandardError; end

      def initialize(baseline:, candidate:)
        @baseline = baseline
        @candidate = candidate
        unless baseline.set_name == candidate.set_name && baseline.set_name.to_s.match?(/-cohort-[0-9a-f]{16}(?:\+verify)?\z/)
          raise Error, 'runs must use the same full comparison cohort'
        end
        raise Error, 'both runs must be complete' unless baseline.status == 'done' && candidate.status == 'done'
        raise Error, 'runs belong to different workspaces' unless baseline.tenant_id == candidate.tenant_id
        raise Error, 'runs use different application revisions' unless baseline.revision == candidate.revision
      end

      def call
        base = by_id(@baseline)
        candidate = by_id(@candidate)
        raise Error, 'question sets do not match' unless base.keys.sort == candidate.keys.sort
        base.each do |id, row|
          raise Error, "question changed: #{id}" unless row['question'] == candidate[id]['question']
          raise Error, "grader missing or changed: #{id}" if row['grader'].blank? || row['grader'] != candidate[id]['grader']
        end

        pairs = base.filter_map do |id, row|
          other = candidate.fetch(id)
          next unless numeric_grade?(row['grade']) && numeric_grade?(other['grade'])

          { 'id' => id, 'cadence' => row['cadence'], 'baseline' => row['grade'], 'candidate' => other['grade'],
            'difference' => (other['grade'] - row['grade']).round(2) }
        end
        differences = pairs.map { |pair| pair['difference'] }
        { 'cohort' => @baseline.set_name, 'baseline_model' => @baseline.model, 'candidate_model' => @candidate.model,
          'questions' => base.size, 'paired_graded' => pairs.size, 'unpaired' => base.size - pairs.size,
          'mean_difference' => differences.empty? ? nil : (differences.sum.to_f / differences.size).round(3),
          'wins' => differences.count(&:positive?), 'ties' => differences.count(&:zero?), 'losses' => differences.count(&:negative?),
          'baseline_ungraded' => base.count { |_, row| !numeric_grade?(row['grade']) },
          'candidate_ungraded' => candidate.count { |_, row| !numeric_grade?(row['grade']) }, 'pairs' => pairs }
      end

      private

      def numeric_grade?(grade) = grade.is_a?(Numeric) && grade.between?(1, 5)

      def by_id(run)
        rows = run.results_list
        raise Error, 'result count does not match requested questions' unless rows.size == run.questions
        ids = rows.map { |row| row['id'].to_s }
        raise Error, 'question IDs are missing or repeated' if ids.any?(&:blank?) || ids.uniq.size != ids.size

        rows.index_by { |row| row['id'].to_s }
      end
    end
  end
end
