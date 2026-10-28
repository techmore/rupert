# frozen_string_literal: true

module TeamChat
  class Battery
    # Retain answers for independent review without sending them to a grader.
    class OfflineGrader
      def label = 'independent review pending'

      def grade(**) = nil
    end
  end
end
