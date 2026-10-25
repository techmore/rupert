# Buzz module (optional, off)

[Buzz](https://github.com/block/buzz) is an open-source, Nostr-based team chat
from Block: one relay is one workspace, messages are signed events, and people and
bots each have a keypair. Rupert used to mirror a Buzz channel; that integration
was retired on 2026-10-22 (PR #323) when Rupert's own team chat took over
(`docs/ops/team-chat.md`).

This module brings the Buzz client back as **one self-contained, optional part
of Rupert that is turned off**. Turned off, Rupert behaves exactly as it does
without it. Team chat is never affected either way.

## Turning it on

The module has a single switch, the `RUPERT_BUZZ_ENABLED` environment variable
on the server (a boot-time variable, like `RUPERT_EMPLOYEE_APP_ENABLED`):

```bash
RUPERT_BUZZ_ENABLED=1   # any other value, or unset, means off
```

It is off by default in every environment (development, test, production).
Restart the web and job processes after changing it. Then, in the workspace:

1. Grant **buzz.read** (and **buzz.post** to let people post and react) on
   Team → Permissions, group "Team chat (Buzz)". No role has them by default,
   so not even administrators see the module until someone grants them.
   Super administrators have every permission already.
2. Open **Team → Buzz → Setup** (needs `settings.write`): enter the relay
   address (`wss://…`) and the default channel id (the UUID Buzz shows),
   **Create identity**, **Publish profile**, then add the shown public key
   (npub) to each channel in Buzz. **Check relay** confirms the relay answers
   and knows the profile.

To turn it off again, unset the variable and restart. Nothing has to be cleaned
up: the data stays in its tables, unused, and `/buzz` goes back to leading to
team chat.

## What it does when on

- **Team → Buzz** (`/buzz/chat`, rail entry in the People group): every Buzz
  channel Rupert's identity belongs to, with unread markers per person, history
  with scrollback, threads, reactions, @mentions, edits and deletions made in
  Buzz, and a composer. The page polls every 4 seconds; Rupert asks the relay at
  most every 6 seconds per workspace (a background `Buzz::SyncJob`), and only
  while someone has the page open.
- **Posting identity:** Rupert holds one Nostr key per workspace. Posts and
  reactions are signed with it and carry the person's name in front
  ("Sam via Rupert: …"). Rupert holds no per-person keys.
- **Untrusted text:** every relay event is checked (id hash, Schnorr signature,
  kind, channel tag, time), cleaned, capped and only ever shown as text. Links
  are never fetched or previewed. Private keys (`nsec…`) are removed from
  incoming text and refused in posts.
- **Retention:** Rupert keeps a copy of the last 30 days; the first sync of each
  day trims older copies. There is no recurring job: `config/recurring.yml` is
  not touched.
- **Setup** (`/buzz/setup`): relay, channel, identity and relay check, plus the
  links people use to add the workspace to their own Buzz app.

Not included (they stay on the `archive/buzz` branch): the `@rupert` AI agent
and its sandbox, Ask Rupert answers in Buzz, account linking, per-person keys,
typing indicators, Rupert notices posted to Buzz, the feedback intake and the
SER8 relay deployment files.

## Configuration and secrets

Per workspace, in Rupert's encrypted settings store (`Setting` rows, the same
place every other connection's credentials live), under the key names the
retired integration used: `BUZZ_RELAY_URL`, `BUZZ_CHANNEL`, `BUZZ_PRIVATE_KEY`.
The private key is created on the Setup page, stored encrypted and never shown,
logged or exported. No secret is in the repository.

## What "off" means

`config/application.rb` requires `lib/buzz.rb` only when the switch is on, so
while it is off none of this code is loaded: no routes (the `/admin/buzz`,
`/buzz` and `/buzz/chat` redirects to `/chat` keep working), no navigation entry,
no permissions in the role editors, no jobs, no browser code in the import map,
no connections to any relay. `test/integration/buzz_module_disabled_test.rb`
in the main suite proves it.

## Layout

A Rails engine (not isolated, so its pages render in Rupert's shell with the
host's helpers), because the module needs its own routes, controllers, views,
browser code and stylesheet, and `web/app/modules/` holds only namespaced models.

```
web/engines/buzz/
  lib/buzz.rb, lib/buzz/engine.rb   switch target; hook points (below)
  config/routes/buzz.rb             drawn by draw(:buzz) in config/routes.rb
  config/importmap.rb               pins the Stimulus controller
  app/models/buzz/                  Message, Channel, ChatRead, Reaction, ChatState, Profile (buzz_* tables)
  app/services/buzz/                Settings, Identity, Socket, RelayClient, Chat, Connect
  app/jobs/buzz/sync_job.rb
  app/controllers/buzz/             ChatController, SetupController
  app/views/buzz/                   chat/show, setup/show, _tabs
  app/javascript/buzz/              buzz_chat_controller.js ("buzz-chat")
  app/assets/stylesheets/buzz/      chat.css (on Rupert's colour tokens)
  test/                             the module's tests, run with the module on
```

Hook points in core, and nothing else:

| Where | What |
| --- | --- |
| `config/application.rb` | the switch: requires the engine when `RUPERT_BUZZ_ENABLED=1`; `config.x.buzz_enabled` |
| `config/routes.rb` | `draw(:buzz) if Rails.application.config.x.buzz_enabled`, before the old redirects |
| `app/models/module_registry.rb` | `ModuleRegistry.register(entry, area:, group:)` for optional modules |
| `app/models/user.rb` | `User.register_permission_group(area:, permissions:)` for optional modules |
| `db/migrate/20261025160000_add_buzz_client_tables.rb` | `buzz_channels`, `buzz_reactions`, `buzz_chat_reads`, and `thread_root` / `edited` on `buzz_messages`; the tables exist whether the module is on or off |
| `.github/workflows/ci.yml` | runs this module's Ruby tests with it on, and its browser tests |

The relay connection is a small blocking WebSocket client on `websocket-driver`
(already bundled with Action Cable), so the module adds no gem.

## Tests

```bash
cd web
RUPERT_BUZZ_ENABLED=1 bin/rails test engines/buzz/test     # the module, turned on
bin/rails test test/integration/buzz_module_disabled_test.rb  # Rupert with it off
node --test engines/buzz/test/javascript/*_test.mjs
```

The module's tests use an in-process stand-in relay on 127.0.0.1
(`test/support/fake_buzz_relay.rb`: NIP-42 sign-in, REQ filters, EVENT/OK).
No test talks to a real relay. Run the module's tests in their own process: the
main suite boots with the module off.
