---
layout: post
title: "One engine for logs, metrics, and traces? Testing the OpenSearch Prometheus integration"
authors:
  - mohiadeen-ameer
date: 2026-11-01
categories:
  - technical-posts
has_science_table: true
meta_keywords: OpenSearch Prometheus integration, PromQL in OpenSearch Dashboards, OpenSearch observability, Discover metrics, unified alerts, Alertmanager, OpenTelemetry, Data Prepper, APM, trace to logs correlation
meta_description: A hands-on test of the OpenSearch Prometheus integration. Follow an injected incident from a PromQL chart to a trace and its logs, see how queries reach Prometheus, and learn two setup details to plan for.
excerpt: OpenSearch Dashboards can now query Prometheus with native PromQL, next to logs and traces stored in OpenSearch. I built a small lab, broke a service on purpose, and tried to find the cause without leaving OpenSearch Dashboards. Here is what worked, how the queries actually reach Prometheus, and two setup details to plan for.
---

OpenSearch 3.5 added PromQL autocomplete and a metrics view in Discover. OpenSearch 3.7 added the native Prometheus integration, and OpenSearch 3.8 lets you create an alert rule from a PromQL query. Put together, the idea is that you can look at logs, traces, and metrics in one place, even though the metrics stay in Prometheus.

I wanted to see how well that works outside a demo, so I set up a small lab, broke one of its services on purpose, and tried to find the cause using only OpenSearch Dashboards. In this post, I'll walk through that investigation, show how a PromQL query gets from your browser to Prometheus, and share two setup details that are worth planning for.

All results come from OpenSearch 3.9.0, OpenSearch Dashboards 3.9.0, Data Prepper 2.16.0, Prometheus 3.15.1, and the OpenTelemetry Collector 0.164.0, running in Docker on a laptop. The full lab, including every configuration file, is available in the [`opensearch-prometheus-lab` repository](https://github.com/mohiadeen-ameer/opensearch-prometheus-lab).

## The lab: One Collector, two storage engines

The application is a two-service shop written in Go and instrumented with the OpenTelemetry SDK. The `checkout` service calls `payments`, which calls a simulated card provider. A load generator sends five requests per second, and the `payments` service exposes a `/chaos` endpoint that adds latency and errors on demand.

The following diagram shows how each signal travels. The OpenTelemetry Collector sends traces and logs to Data Prepper, which writes them to OpenSearch. Metrics go directly to Prometheus through its native OTLP receiver. Data Prepper also derives rate, error, and duration (RED) metrics from spans and remote-writes them to Prometheus for the application performance monitoring (APM) pages.

![Architecture of the lab: the OpenTelemetry Collector sends traces and logs through Data Prepper to OpenSearch, and metrics to Prometheus. OpenSearch Dashboards queries OpenSearch, which forwards PromQL to Prometheus.](/assets/media/blog-images/2026-11-01-testing-opensearch-prometheus-integration/architecture.png){:class="img-centered"}

Connecting Prometheus takes one API call to OpenSearch Dashboards:

```bash
curl -X POST localhost:5601/api/directquery/dataconnections \
  -H 'osd-xsrf: true' -H 'Content-Type: application/json' -d '{
  "name": "lab_prometheus", "connector": "prometheus", "allowedRoles": [],
  "properties": {
    "prometheus.uri": "http://prometheus:9090",
    "alertmanager.uri": "http://alertmanager:9093"
  }
}'
```

The new experience also needs an Observability workspace and the `explore` settings in `opensearch_dashboards.yml`. The lab's `setup.sh` script creates both. For all options, see [Analyzing metrics in Discover](https://docs.opensearch.org/latest/observing-your-data/exploring-observability-data/discover-metrics/).

## Where a PromQL query goes

Before running the investigation, I wanted to know which component talks to Prometheus. I recorded the requests that the browser sends and then read the OpenSearch Dashboards server code that handles them. The following diagram shows the path of a single PromQL query.

![Request path of a PromQL query: the browser calls OpenSearch Dashboards, which calls the OpenSearch direct query API, which calls the Prometheus HTTP API.](/assets/media/blog-images/2026-11-01-testing-opensearch-prometheus-integration/promql-request-path.png){:class="img-centered"}

OpenSearch, not OpenSearch Dashboards, is the proxy. The Prometheus connection is stored in the OpenSearch SQL plugin's data source registry, which is why the cluster needs the `plugins.query.datasources.encryption.masterkey` setting: the plugin uses that key to encrypt stored data source credentials. This design gives you one place to manage the connection.

You can call the same API yourself. The query is passed to Prometheus unchanged, so any expression that works in your recording rules works here:

```bash
curl -X POST localhost:9200/_plugins/_directquery/_query/lab_prometheus \
  -H 'Content-Type: application/json' -d '{
  "query": "sum by (result) (rate(shop_orders_total[1m]))",
  "language": "promql",
  "options": { "queryType": "instant", "time": "'"$(date +%s)"'" }
}'
```

## Following an incident from a metric to a log line

With traffic flowing, I made the card provider slow and unreliable:

```bash
curl "localhost:8081/chaos?latency_ms=700&error_rate=0.25"
```

I started from a PromQL query, and every step stayed inside one OpenSearch Dashboards workspace.

### Step 1: Spot the problem in metrics

In **Discover > Metrics**, the **Explore** mode found every metric name in Prometheus (388 in this lab) without any configuration and drew a small chart for each one. The following image shows the Explore mode.

![Explore mode in Discover Metrics, showing a grid of preview charts, one for each Prometheus metric.](/assets/media/blog-images/2026-11-01-testing-opensearch-prometheus-integration/explore-metrics.png)

Next, I switched to **Query** mode and entered a p95 latency query. The visual builder and the code editor stay in sync, so the builder splits the expression into function, aggregation, and metric steps. If you are still learning PromQL, this is a useful way to see how an expression is structured:

```promql
histogram_quantile(0.95,
  sum by (le, service_name) (rate(http_server_request_duration_seconds_bucket[1m])))
```

The following chart shows p95 latency for both services jumping from about 50 ms to about 750 ms when the fault starts.

![PromQL query in the builder and a line chart showing p95 latency rising from about 50 ms to about 750 ms for both services.](/assets/media/blog-images/2026-11-01-testing-opensearch-prometheus-integration/promql-p95-latency.png)

The `service_name` label exists because Prometheus is configured to promote the OpenTelemetry `service.name` resource attribute to a label (`otlp.promote_resource_attributes` in `prometheus.yml`). The same `service.name` value is stored on every span and log in OpenSearch. That shared key is what lets you move between signals, so plan for it from the start.

### Step 2: Check which alerts fired

Both Prometheus alerting rules in the lab fired within about two minutes (each rule waits for one minute before firing). The **Alerts** page lists Prometheus alerts with their severity, state, and labels, next to OpenSearch alerting monitors, and you can filter by data source. The following image shows the two active alerts.

![The Alerts page showing two active Prometheus alerts: CheckoutErrorRateHigh with critical severity and PaymentsLatencyHigh with medium severity.](/assets/media/blog-images/2026-11-01-testing-opensearch-prometheus-integration/prometheus-alerts.png)

The **Routing** tab shows a read-only view of the Alertmanager routing tree, which helps you answer "who was notified?" without opening Alertmanager. The following image shows the lab's routing tree.

![The Routing tab showing the Alertmanager route tree with a catch-all receiver and an on-call receiver for critical alerts.](/assets/media/blog-images/2026-11-01-testing-opensearch-prometheus-integration/alertmanager-routing.png)

### Step 3: Find the slow span

In **Discover > Traces**, I filtered for failed requests and opened one. The following waterfall shows that every span in the request takes about 734 ms and that the deepest span, `card-provider.authorize`, is where the time goes.

![Trace waterfall for a failed checkout request, with four nested spans of about 734 ms each and card-provider.authorize as the deepest span.](/assets/media/blog-images/2026-11-01-testing-opensearch-prometheus-integration/trace-waterfall.png)

### Step 4: Read the related logs

The **Related logs** tab on the same trace shows the log lines written during that request, joined on the trace ID. The following image shows one error log from each service, including the root cause: a card provider timeout.

![Related logs tab showing two error logs for the trace: checkout failed and card provider timeout.](/assets/media/blog-images/2026-11-01-testing-opensearch-prometheus-integration/trace-related-logs.png)

So in four steps I got from a latency spike to the actual error message without opening another tool, and the metrics never left Prometheus. This part worked as advertised.

## Two setup details to plan for

Two details took me some time to work out during setup, so here's what to expect.

### Creating alert rules requires a Prometheus backend with a ruler API

When you query a Prometheus data source with PromQL, the toolbar shows a **Create alert rule** action. Saving a rule sends the rule group to OpenSearch, which forwards it to the data source's ruler endpoint. Open-source Prometheus loads rules from files and has no API for writing them. Sending the same request directly returned the following error:

```json
{
  "type": "PrometheusClientException",
  "reason": "Invalid Request",
  "details": "Ruler request failed with code: 404. Error details: 404 page not found"
}
```

Reading rules works: the **Alerts** and **Rules** tabs showed the lab's file-based rules. To create rules from OpenSearch Dashboards, use a backend that provides a ruler API, such as Cortex, Grafana Mimir, or Amazon Managed Service for Prometheus, and set it as `prometheus.ruler.uri` on the data source. The [OpenSearch Observability Stack](https://github.com/opensearch-project/observability-stack) uses Cortex for this reason.

### Refresh the field list of datasets that you create using the API

I created the logs and traces datasets with the saved objects API. Discover opened them, but each page showed the error `Could not locate that index-pattern-field (id: time)`, and the **Related logs** tab returned no results.

Datasets created using the API start with an empty field list. The fix is to load the fields once with `GET /api/index_patterns/_fields_for_wildcard` and save them on the dataset, which is what the dataset creation wizard does. The lab's `setup.sh` script does this, so run it after data has started arriving.

## What it costs to run

The following table lists the steady-state memory usage at 5 requests per second, measured after about 15 minutes.

| Component | Memory |
| :--- | ---: |
| OpenSearch (1 GB heap) | 1.9 GB |
| Data Prepper | 470 MB |
| OpenSearch Dashboards | 390 MB |
| OpenTelemetry Collector | 135 MB |
| Prometheus | 75 MB |
| Alertmanager and the three demo services | 65 MB |

At that point, OpenSearch held 18,500 spans (7 MB) and 7,300 log records (2.4 MB), and Prometheus held about 1,300 active series.

## What I didn't test

This was a small test, so treat these results as a starting point. The lab runs a single OpenSearch node with the Security plugin disabled, one Prometheus server, and only 5 requests per second. I didn't test authentication to Prometheus, high-availability or federated Prometheus setups, a ruler-enabled backend such as Cortex, or the service-level objective catalog.

## So, is it one engine?

Not in this setup. OpenSearch doesn't store the metrics; it forwards PromQL to Prometheus and shows the results. I think that's a reasonable choice: my existing Prometheus rules kept working, and I didn't have to move any data.

If you do want metrics stored in OpenSearch itself, the [Time-Series Database plugin](https://github.com/opensearch-project/time-series-db) and the Data Prepper `index_type: tsdb` sink option introduced in [Data Prepper 2.16](https://opensearch.org/blog/data-prepper-2-16/) are worth looking at. I haven't tested that option yet.

If you already run Prometheus and OpenSearch side by side, the integration saves you from switching between two UIs, and it took me very little setup. Just plan for the two setup details above.

## Next steps

To try the integration yourself, run the lab:

```bash
git clone https://github.com/mohiadeen-ameer/opensearch-prometheus-lab
cd opensearch-prometheus-lab
docker compose up -d --build
sleep 60 && ./setup.sh
curl "localhost:8081/chaos?latency_ms=700&error_rate=0.25"
```

Then open `http://localhost:5601`, select the **Shop observability** workspace, and follow the same four steps.

Before you adopt the integration, check the following:

- If you want to create alert rules from OpenSearch Dashboards, make sure your Prometheus backend provides a ruler API.
- Make sure that `service.name` is promoted to a Prometheus label so that you can correlate metrics with traces and logs.

To learn more, see [Analyzing metrics in Discover](https://docs.opensearch.org/latest/observing-your-data/exploring-observability-data/discover-metrics/) and the [OpenSearch Observability Stack](https://opensearch.org/platform/observability-stack/). If you reproduce or extend these results, share them on the [OpenSearch forum](https://forum.opensearch.org/) or open an issue in the [lab repository](https://github.com/mohiadeen-ameer/opensearch-prometheus-lab).
