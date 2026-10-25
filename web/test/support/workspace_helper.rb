# frozen_string_literal: true

# A fresh workspace (tenant) for tests that need their own, modelled on
# WalkthroughHelper#synthetic_workspace. The subdomain is unique so parallel
# workers and repeated setups never collide.
#
#   @tenant = create_workspace('Concurrent holds')
#   other = create_workspace('Other store', current: false)
#
# It becomes Current.tenant unless current: false. Extra attributes go to
# Tenant.create! (for example status: 'active').
module WorkspaceHelper
  def create_workspace(name = 'Test workspace', current: true, **attributes)
    slug = name.parameterize.first(50).delete_suffix('-').presence || 'workspace'
    tenant = Tenant.create!(name: name, subdomain: "#{slug}-#{SecureRandom.hex(4)}", **attributes)
    Current.tenant = tenant if current
    tenant
  end
end
