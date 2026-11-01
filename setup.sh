#!/usr/bin/env bash
# Wires OpenSearch Dashboards to both backends. Safe to re-run.
#   1. Prometheus data source "lab_prometheus" (stored in OpenSearch by the SQL plugin)
#   2. Observability workspace "Shop observability"
#   3. Datasets for logs, spans and the APM service map (OpenSearch indices)
#   4. Correlations: trace -> logs, and the APM config (spans + service map + Prometheus)
set -euo pipefail
OSD="${DASHBOARDS_URL:-http://localhost:5601}"
WS_NAME="Shop observability"

api() { # api METHOD PATH [JSON]
  curl -sf -X "$1" "$OSD$2" -H 'osd-xsrf: true' -H 'Content-Type: application/json' ${3:+-d "$3"}
}
json() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

until curl -sf "$OSD/api/status" | grep -q '"state":"green"'; do echo "waiting for Dashboards..."; sleep 5; done

# 1. Prometheus data source. The URL is the address OpenSearch uses, inside the Docker network.
if ! api GET /api/dataconnections | grep -q '"lab_prometheus"'; then
  api POST /api/directquery/dataconnections '{
    "name": "lab_prometheus", "connector": "prometheus", "allowedRoles": [],
    "properties": {"prometheus.uri": "http://prometheus:9090", "alertmanager.uri": "http://alertmanager:9093"}}' >/dev/null
fi
PROM_ID=$(api GET '/api/saved_objects/_find?type=data-connection&per_page=100' |
  json '[o["id"] for o in d["saved_objects"] if o["attributes"].get("connectionId")=="lab_prometheus"][0]')
echo "prometheus data source: lab_prometheus ($PROM_ID)"

# 2. Workspace with the observability use case (enables Discover logs/traces/metrics and APM).
WS=$(api POST /api/workspaces/_list '{}' |
  json "next((w['id'] for w in d['result']['workspaces'] if w['name']=='$WS_NAME'), '')")
if [ -z "$WS" ]; then
  WS=$(api POST /api/workspaces "{\"attributes\":{\"name\":\"$WS_NAME\",\"features\":[\"use-case-observability\"]}}" |
    json 'd["result"]["id"]')
fi
api POST /api/workspaces/_associate "{\"workspaceId\":\"$WS\",\"savedObjects\":[{\"type\":\"data-connection\",\"id\":\"$PROM_ID\"}]}" >/dev/null
echo "workspace: $WS_NAME ($WS)"

# 3. Datasets. signalType tells Discover which experience (logs or traces) to open them in.
dataset() { # dataset ID TITLE TIMEFIELD [SIGNAL] [SCHEMA]
  local attrs="\"title\":\"$2\",\"timeFieldName\":\"$3\""
  [ -n "${4:-}" ] && attrs="$attrs,\"signalType\":\"$4\""
  [ -n "${5:-}" ] && attrs="$attrs,\"schemaMappings\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$5")"
  # Datasets created through the API start with an empty field list, and Discover then fails with
  # "Could not locate that index-pattern-field". Fetch the fields now, the way the UI wizard does.
  # The indices must already have data, so start the stack and wait a minute before running this.
  local fields
  if fields=$(api GET "/w/$WS/api/index_patterns/_fields_for_wildcard?pattern=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$2")" |
      json 'json.dumps(json.dumps(d["fields"]))'); then
    attrs="$attrs,\"fields\":$fields"
  else
    echo "  $2 has no data yet: run ./setup.sh again in a minute" >&2
  fi
  api POST "/w/$WS/api/saved_objects/index-pattern/$1?overwrite=true" "{\"attributes\":{$attrs}}" >/dev/null
}
dataset lab-logs  'logs-otel-v1*'            time      logs \
  '{"otelLogs":{"timestamp":"time","traceId":"traceId","spanId":"spanId","serviceName":"resource.attributes.service.name"}}'
dataset lab-spans 'otel-v1-apm-span*'        endTime   traces
dataset lab-svcmap 'otel-v2-apm-service-map*' timestamp
api POST "/w/$WS/api/opensearch-dashboards/settings" '{"changes":{"defaultIndex":"lab-logs"}}' >/dev/null
echo "datasets: logs-otel-v1*, otel-v1-apm-span*, otel-v2-apm-service-map*"

# 4. Correlations (saved objects that power "view logs for this trace" and the APM pages).
correlation() { # correlation ID BODY
  api POST "/w/$WS/api/saved_objects/correlations/$1?overwrite=true" "$2" >/dev/null
}
correlation lab-trace-to-logs "{
  \"attributes\": {\"correlationType\": \"trace-to-logs-otel-v1-apm-span*\", \"title\": \"trace-to-logs_otel-v1-apm-span*\",
    \"version\": \"1.0.0\", \"entities\": [{\"tracesDataset\": {\"id\": \"references[0].id\"}}, {\"logsDataset\": {\"id\": \"references[1].id\"}}]},
  \"references\": [{\"name\": \"entities[0].index\", \"type\": \"index-pattern\", \"id\": \"lab-spans\"},
                   {\"name\": \"entities[1].index\", \"type\": \"index-pattern\", \"id\": \"lab-logs\"}],
  \"workspaces\": [\"$WS\"]}"
correlation lab-apm-config "{
  \"attributes\": {\"correlationType\": \"APM-Config-$WS\", \"title\": \"apm-config\", \"version\": \"1.0.0\",
    \"entities\": [{\"tracesDataset\": {\"id\": \"references[0].id\"}}, {\"serviceMapDataset\": {\"id\": \"references[1].id\"}},
                   {\"prometheusDataSource\": {\"id\": \"references[2].id\"}}]},
  \"references\": [{\"name\": \"entities[0].index\", \"type\": \"index-pattern\", \"id\": \"lab-spans\"},
                   {\"name\": \"entities[1].index\", \"type\": \"index-pattern\", \"id\": \"lab-svcmap\"},
                   {\"name\": \"entities[2].dataConnection\", \"type\": \"data-connection\", \"id\": \"$PROM_ID\"}],
  \"workspaces\": [\"$WS\"]}"
echo "correlations: trace-to-logs, apm-config"

echo
echo "open: $OSD/w/$WS/app/explore/metrics"
