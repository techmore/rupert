# frozen_string_literal: true

# Drawn into Rupert's routes by `draw(:buzz)` (config/routes.rb), only while the
# module is on. They come before the old /buzz -> /chat redirects, which take
# over again the moment the module is turned off.
scope '/buzz', module: 'buzz', as: 'buzz' do
  get '/', to: redirect('/buzz/chat')
  get 'chat', to: 'chat#show', as: :chat
  get 'chat/messages', to: 'chat#messages', as: :chat_messages
  post 'chat/messages', to: 'chat#create'
  get 'chat/channels', to: 'chat#channels', as: :chat_channels
  get 'chat/members', to: 'chat#members', as: :chat_members
  get 'chat/threads/:id', to: 'chat#thread', as: :chat_thread, constraints: { id: /\h{64}/ }
  post 'chat/reactions', to: 'chat#react', as: :chat_reactions
  post 'chat/read', to: 'chat#read', as: :chat_read

  get 'setup', to: 'setup#show', as: :setup
  patch 'setup', to: 'setup#update'
  post 'setup/keypair', to: 'setup#keypair', as: :setup_keypair
  post 'setup/profile', to: 'setup#profile', as: :setup_profile
  post 'setup/check', to: 'setup#check', as: :setup_check
end
