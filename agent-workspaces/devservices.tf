# Excerpt from the Coder template: local.db_password, local.dbs and coder_agent.main are defined in main.tf.
# Dev services for each workspace: Postgres (TimescaleDB image, a superset of plain Postgres 17) and Redis.
# They sit on an internal Docker network with no internet and no published ports; only this workspace's container
# joins it and reaches them as "postgres" and "redis". Connection strings are in the agent env (main.tf local.dev_env).
# The database volume persists like the home volume; Redis is a throwaway cache.

locals {
  ws_prefix = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  # pinned to digests like the rest of the lab (release >= 2 weeks old)
  pg_image    = "timescale/timescaledb:2.30.2-pg17@sha256:b346edcdb51a1fd6020e3965e0bd1c9f3406fa6d5fbce1e28f4852587ef934e2"
  redis_image = "redis:7.4.12-alpine@sha256:7f7d30b7fdd09467bac58198a1f166dd69789d348d4fe859cccb20e0cf287fbe"
  # Mailpit v1.33.0 (2026-10-31): SMTP sink, nothing is delivered; web UI/API on :8025
  mailpit_image = "axllent/mailpit:v1.33.0@sha256:9b3a463be15354c0f0eba91697d80e3e0d8a5623ef0e627cacc836bc17fd5231"
}

resource "docker_image" "pg" {
  name         = local.pg_image
  keep_locally = true
}

resource "docker_image" "redis" {
  name         = local.redis_image
  keep_locally = true
}

resource "docker_image" "mailpit" {
  name         = local.mailpit_image
  keep_locally = true
}

resource "docker_network" "dev" {
  name     = "coder-${data.coder_workspace.me.id}-dev"
  internal = true
  # explicit subnet: without one Docker picked a range that a LAN behind the VPN also uses (its daemon had never
  # loaded default-address-pools). 172.30.<hash>.0/24 is per workspace; a clash fails the build loudly.
  ipam_config {
    subnet = "172.30.${parseint(substr(sha256(data.coder_workspace.me.id), 0, 2), 16)}.0/24"
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_volume" "pg" {
  name = "coder-${data.coder_workspace.me.id}-pg"
  lifecycle {
    ignore_changes = all
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

resource "docker_container" "postgres" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.pg.image_id
  name     = "${local.ws_prefix}-postgres"
  hostname = "postgres"
  env = [
    "POSTGRES_USER=dev",
    "POSTGRES_PASSWORD=${local.db_password}",
    "POSTGRES_DB=app",
    "TS_TUNE_MEMORY=512MB",
  ]
  memory  = 1024
  restart = "unless-stopped"
  networks_advanced {
    name    = docker_network.dev.name
    aliases = ["postgres"]
  }
  volumes {
    container_path = "/var/lib/postgresql/data"
    volume_name    = docker_volume.pg.name
  }
  # runs only when the data volume is empty (first start)
  upload {
    file    = "/docker-entrypoint-initdb.d/10-dev-dbs.sql"
    content = join("\n", [for d in local.dbs : "CREATE DATABASE ${d};"])
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_container" "redis" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.redis.image_id
  name     = "${local.ws_prefix}-redis"
  hostname = "redis"
  command  = ["redis-server", "--appendonly", "no", "--maxmemory", "200mb", "--maxmemory-policy", "allkeys-lru"]
  memory   = 256
  restart  = "unless-stopped"
  networks_advanced {
    name    = docker_network.dev.name
    aliases = ["redis"]
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_container" "mailpit" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.mailpit.image_id
  name     = "${local.ws_prefix}-mailpit"
  hostname = "mailpit"
  env = [
    "MP_SMTP_AUTH_ACCEPT_ANY=1",
    "MP_SMTP_AUTH_ALLOW_INSECURE=1",
    "MP_MAX_MESSAGES=1000",
  ]
  memory  = 128
  restart = "unless-stopped"
  networks_advanced {
    name    = docker_network.dev.name
    aliases = ["mailpit"]
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

# Mailpit web UI in the Coder dashboard (the agent proxies to the dev network)
resource "coder_app" "mail" {
  agent_id     = coder_agent.main.id
  slug         = "mail"
  display_name = "Mail (Mailpit)"
  icon         = "/emojis/1f4e7.png"
  url          = "http://mailpit:8025"
  subdomain    = false
  share        = "owner"
}
