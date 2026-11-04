#!/usr/bin/env bash
# Creates a Prometheus data connection limited to the "promreaders" role, then sends
# the same PromQL query as three users:
#   alice  - direct query permissions, in promreaders  -> data
#   bob    - direct query permissions, not in promreaders -> HTTP 200, empty result
#   carol  - no permissions                             -> HTTP 403
set -euo pipefail
cd "$(dirname "$0")"
ADMIN='admin:Lab_Test_Pass_123!'; USER_PASS='Lab_User_Pass_456!'; OS=https://localhost:9201
api() { curl -sk -u "$ADMIN" -H 'Content-Type: application/json' "$@"; }

docker compose up -d >/dev/null
until curl -sk -u "$ADMIN" "$OS/_cluster/health" | grep -q status; do echo "waiting for OpenSearch..."; sleep 5; done

api -X DELETE "$OS/_plugins/_query/_datasources/lab_prometheus" >/dev/null || true
api -X POST "$OS/_plugins/_query/_datasources" -d '{
  "name": "lab_prometheus", "connector": "prometheus", "allowedRoles": ["promreaders"],
  "properties": {"prometheus.uri": "http://prometheus:9090", "prometheus.auth.type": "basicauth",
                 "prometheus.auth.username": "svc", "prometheus.auth.password": "secret-pass"}}' >/dev/null

PERMS='{"cluster_permissions":["cluster:admin/opensearch/ql/datasources/read","cluster:admin/opensearch/direct_query/*"]}'
for u in alice bob carol; do api -X PUT "$OS/_plugins/_security/api/internalusers/$u" -d "{\"password\":\"$USER_PASS\"}" >/dev/null; done
api -X PUT "$OS/_plugins/_security/api/roles/promreaders" -d "$PERMS" >/dev/null
api -X PUT "$OS/_plugins/_security/api/roles/otherrole" -d "$PERMS" >/dev/null
api -X PUT "$OS/_plugins/_security/api/rolesmapping/promreaders" -d '{"users":["alice"]}' >/dev/null
api -X PUT "$OS/_plugins/_security/api/rolesmapping/otherrole" -d '{"users":["bob"]}' >/dev/null
sleep 2

QUERY='{"query":"sum(rate(shop_orders_total[1m]))","language":"promql","options":{"queryType":"instant","time":"'$(date +%s)'"}}'
for u in alice bob carol; do
  printf '%-6s ' "$u"
  curl -sk -u "$u:$USER_PASS" -H 'Content-Type: application/json' -o /tmp/promlab-$u.json -w 'HTTP %{http_code}  ' \
    -X POST "$OS/_plugins/_directquery/_query/lab_prometheus" -d "$QUERY"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d.get("results",{}).get("lab_prometheus"); print("data" if r and r.get("result") else ("empty result" if r is not None else d.get("error",{}).get("type","")))' /tmp/promlab-$u.json
done
printf 'stored credentials returned by the API: '
api "$OS/_plugins/_query/_datasources/lab_prometheus" | python3 -c 'import json,sys; p=json.load(sys.stdin)["properties"]; print(sorted(p))'
echo "Stop with: docker compose -f security-test/docker-compose.yml down -v"
