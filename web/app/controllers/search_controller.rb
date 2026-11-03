# frozen_string_literal: true

# Global search. The header's command palette gets a small JSON result set; the iPhone app's
# Search tab opens /search as a page, so it gets the same results as a list.
class SearchController < AuthenticatedController
  def index
    authorize(:module, :dashboard_read?)
    if search_page?
      @query = params[:q].to_s.strip
      @results = SearchService.search(@query, limit: 40)
      return render(:index)
    end
    render(json: SearchService.search(params[:q]))
  end

  private

  def search_page?
    hotwire_native_app? && !request.xhr? && !request.format.json?
  end
end
