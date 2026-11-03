# frozen_string_literal: true

# The browser half of WebMCP for signed-in people (docs/webmcp.md). The page's
# lib/webmcp.js fetches the tool list here when the browser has
# document.modelContext, registers each tool, and sends each call back here.
#
# This is an ordinary signed-in endpoint: the browser session, CSRF token,
# employee-workspace restriction, Rack::Attack limits and the person's current
# permissions all apply exactly as for any other page. No token is issued.
class WebMcpController < AuthenticatedController
  MAX_BODY_BYTES = 64.kilobytes

  before_action :no_store
  before_action :authorize_webmcp

  rescue_from ActionController::InvalidAuthenticityToken do
    render json: { content: [{ type: 'text', text: 'The page session expired. Reload the page and try again.' }], isError: true, error: 'csrf' },
      status: :unprocessable_content
  end

  # GET /webmcp/tools — the tools this person may use now.
  def index
    render json: { key: WebMcp::Registry.key_for(Current.user), endpoint: webmcp_tools_path,
                   tools: WebMcp::Registry.definitions_for(Current.user) }
  end

  # POST /webmcp/tools/:name — run one tool as this person. Body: { arguments: {...}, confirmed: true|false }.
  def create
    return render(json: { isError: true, error: 'too_large' }, status: :content_too_large) if request.content_length.to_i > MAX_BODY_BYTES

    arguments = params[:arguments].respond_to?(:to_unsafe_h) ? params[:arguments].to_unsafe_h : {}
    confirmed = ActiveModel::Type::Boolean.new.cast(params[:confirmed]) == true
    result = WebMcp::Runner.new(user: Current.user, client: request.user_agent).call(params[:name], arguments, confirmed: confirmed)
    render json: result.payload, status: result.status
  end

  private

  def no_store
    response.headers['Cache-Control'] = 'no-store'
  end

  def authorize_webmcp
    authorize(:web_mcp, :use?)
  end

  def user_not_authorized(_error = nil)
    render json: { content: [{ type: 'text', text: 'Browser tools are not available to this account.' }], isError: true, error: 'denied' },
      status: :forbidden
  end
end
