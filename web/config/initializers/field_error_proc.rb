# frozen_string_literal: true

# Style Rails' automatic field_with_errors wrapper so invalid fields are
# visible (red ring) instead of silently breaking layout. Keeps the element
# itself (default wrapper strips and re-adds it, shifting markup).
ActionView::Base.field_error_proc = lambda do |html_tag, _instance|
  if html_tag =~ /<(input|select|textarea)/
    html_tag.gsub(/class="/, 'class="!border-rose !ring-1 !ring-rose ').html_safe
  else
    html_tag.html_safe
  end
end
