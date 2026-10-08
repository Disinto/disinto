# vault/policies/service-healer.hcl
#
# Read access to kv/disinto/notify/telegram for the healer job
# (nomad/jobs/healer.hcl, #1951). The healer restarts the failing layer when a
# public endpoint is down (#1952) and, when its own fix did not work, messages
# the owner by Telegram (#1955) — that message needs the bot token and chat
# id from this path (keys bot_token, chat_id; seeded by hand, not this
# change).
#
# Modeled on service-edge-chat (kv/disinto/chat): a read grant on a single
# specific disinto KV path, no list.
#
# Separate from service-edge-chat (chat) and the per-secret runner policies.

path "kv/data/disinto/notify/telegram" {
  capabilities = ["read"]
}
