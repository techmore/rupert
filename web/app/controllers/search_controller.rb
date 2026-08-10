# frozen_string_literal: true

# Global search (command palette). Returns a small JSON result set.
class SearchController < AuthenticatedController
  def index
    authorize(:module, :dashboard_read?)
    render(json: SearchService.search(params[:q]))
  end
end
