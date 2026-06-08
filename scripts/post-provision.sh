#!/usr/bin/env bash
set -euo pipefail

log()  { echo "[INFO]  $*"; }
ok()   { echo "[OK]    $*"; }
err()  { echo "[ERROR] $*" >&2; }
warn() { echo "[WARN]  $*"; }

log "Loading Terraform outputs..."

TF_OUT="$(terraform -chdir=infra output -json 2>/dev/null || true)"
if [[ -z "$TF_OUT" ]]; then
  err "Terraform outputs missing"
  exit 1
fi

read_tf() { echo "$TF_OUT" | jq -r ".${1}.value // empty"; }

AGENT_ID="$(read_tf agent_id)"

log "Resolving agent data plane endpoint..."
AGENT_ENDPOINT="$(az resource show --ids "$AGENT_ID" --query "properties.agentEndpoint" -o tsv 2>/dev/null || true)"
if [[ -z "$AGENT_ENDPOINT" ]]; then
  err "Could not resolve agent endpoint from properties.agentEndpoint"
  exit 1
fi

log "Acquiring access token..."
ACCESS_TOKEN="$(az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv)"
if [[ -z "$ACCESS_TOKEN" ]]; then
  err "Could not acquire access token — run 'az login' first"
  exit 1
fi

ok "Agent ID: $AGENT_ID"
ok "Agent endpoint: $AGENT_ENDPOINT"

# Load knowledge base (upload each md file individually)
log "Loading knowledge base..."
for kb_file in \
  knowledge-base/http-500-errors.md \
  knowledge-base/change-risk-assessment.md \
  knowledge-base/github-issue-triage.md \
  knowledge-base/on-call-handoff.md \
  knowledge-base/orders-architecture.md
do
  log "  Uploading $kb_file..."
  curl -s -X POST "$AGENT_ENDPOINT/knowledge/load" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: text/markdown" \
    -H "X-Document-Id: $(basename "$kb_file" .md)" \
    --data-binary "@$kb_file"
done
ok "Knowledge loaded"

# 5/7 — Register skills (S2)
log "Registering skills..."
for skill_file in \
  .github/skills/containerapps-500-diagnostics/SKILL.md \
  .github/skills/provision-incident-response-plan/SKILL.md
do
  skill_id="$(basename "$(dirname "$skill_file")")"
  log "  Registering ${skill_id}..."
  curl -s -X POST "$AGENT_ENDPOINT/skills/register" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: text/markdown" \
    -H "X-Skill-Id: ${skill_id}" \
    --data-binary "@${skill_file}"
done
ok "Skills registered"

# 6/7 — Register subagents (upload each yaml file individually)
log "Registering subagents..."
for agent_file in \
  sre-config/agents/orchestrator-agent.yaml \
  sre-config/agents/triage-agent.yaml \
  sre-config/agents/issue-triager.yaml
do
  log "  Registering $(basename "$agent_file")..."
  curl -s -X POST "$AGENT_ENDPOINT/subagents/register" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/yaml" \
    -H "X-Agent-Id: $(basename "$agent_file" .yaml)" \
    --data-binary "@$agent_file"
done
ok "Subagents registered"

# 7/7 — Register approval hook 
if [[ -n "${APPROVAL_WEBHOOK_URL:-}" ]]; then
  log "Registering approval hook..."
  HOOK_YAML=$(sed "s|\${APPROVAL_WEBHOOK_URL}|$APPROVAL_WEBHOOK_URL|g" sre-config/hooks/approval-hook.yaml)
  echo "$HOOK_YAML" | curl -s -X POST "$AGENT_ENDPOINT/hooks/register" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/yaml" \
    -H "X-Hook-Id: require-approval-on-write" \
    --data-binary @-
  ok "Approval hook registered"
else
  warn "APPROVAL_WEBHOOK_URL not set — skipping hook registration (S4). Set it and rerun with --hooks-only to enable."
fi

ok "Post-provision setup completed successfully"