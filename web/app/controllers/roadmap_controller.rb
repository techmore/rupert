# frozen_string_literal: true

# Product information only; viewing a roadmap never enables a platform write.
class RoadmapController < AuthenticatedController
  # Open to every signed-in account (ModuleRegistry 'roadmap' has no permission): static product JSON, no workspace data.
  skip_after_action :verify_authorized

  def index
    @catalog = JSON.parse(Rails.root.join('config/product_roadmap.json').read)
  end
end
