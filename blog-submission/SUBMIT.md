# Submitting the blog post to opensearch.org

The files in this folder use the same paths as the
[opensearch-project/project-website](https://github.com/opensearch-project/project-website) repository,
so they can be copied straight into a fork of it.

| File | Goes to |
| --- | --- |
| `_posts/2026-11-01-testing-opensearch-prometheus-integration.md` | the post |
| `assets/media/blog-images/2026-11-01-testing-opensearch-prometheus-integration/` | its 8 images |
| `_community_members/mohiadeen-ameer.md` | your author profile |
| `assets/media/community/members/mohiadeen-ameer.jpg` | **you add this**: a square photo of yourself |

## Before you submit

1. **Fill in the two TODOs** in `_community_members/mohiadeen-ameer.md`: job title and company, and a one-line bio.
2. **Add your photo** as `assets/media/community/members/mohiadeen-ameer.jpg`.
3. **Read the post once and make it sound like you.** Reviewers may ask about the APM percentile finding. The short
   version: Data Prepper writes per-bucket counts, Prometheus `histogram_quantile` expects cumulative ones, so the
   "p99" lands in the bucket with the most samples. Hand-computing it from the table gives exactly the 49.709 ms the page showed.
4. (Recommended) **Open a Data Prepper issue** for the histogram buckets first, and link it in the post. Text below.

## Step 1: open a blog issue

Go to https://github.com/opensearch-project/project-website/issues/new/choose → **New blog post**:

- **Describe the blog post:** A hands-on test of the native Prometheus integration in OpenSearch 3.9. Using a
  reproducible Docker lab (Go services instrumented with OpenTelemetry, Data Prepper, Prometheus, Alertmanager), the
  post follows an injected incident from a PromQL chart in Discover Metrics to unified alerts, a trace waterfall, and
  related logs. It explains how PromQL queries are proxied through the OpenSearch direct query API, and covers two
  setup details: alert rule creation requiring a ruler API (Cortex, Mimir, or Amazon Managed Service for Prometheus), and
  field refresh for datasets created using the API.
- **Expected title:** One engine for logs, metrics, and traces? Testing the OpenSearch Prometheus integration
- **Author's name:** Mohiadeen Ameer
- **Author's email:** github.com/mohiadeen-ameer
- **Category:** technical

## Step 2: fork and open a pull request

1. Fork https://github.com/opensearch-project/project-website.
2. Copy this folder's `_posts`, `_community_members`, and `assets` into the fork.
3. Commit with a DCO sign-off (required): `git commit -s -m "Add blog post: testing the OpenSearch Prometheus integration"`.
4. Open a pull request. Description:

   > Adds a technical blog post testing the OpenSearch Prometheus integration (OpenSearch 3.9.0), with author profile
   > and images. Closes #<blog issue number>.

5. The marketing team may replace `meta_keywords` and `meta_description`, and the editorial team will review the
   text and set the final `date` (and rename the files to match).

## Optional: Data Prepper issue text

Title: **otel_apm_service_map: latency histogram buckets are non-cumulative, so histogram_quantile is wrong**

> With Data Prepper 2.16.0 (`otel_apm_service_map` → `prometheus` sink → Prometheus 3.15.1), `latency_seconds_bucket`
> samples are per-bucket counts: over 15 minutes the buckets sum exactly to `latency_seconds_count` and `le="+Inf"`
> is 0. Prometheus expects cumulative buckets. `histogram_quantile` then enforces monotonicity with a running max,
> so the quantile falls in the most populated bucket. The OpenSearch Dashboards APM page (3.9.0) uses
> `histogram_quantile(0.99, sum by (environment, service, le) (sum_over_time(latency_seconds_bucket{...}[15m])))`
> and showed p99 = 49.7 ms while real p95 was ~750 ms (the 15-minute window mixed fast requests from before a 700 ms latency fault with slow ones after it).
>
> Bucket counts (le → count): 0.025→209, 0.05→1492, 0.075→94, 0.1→0, 0.25→0, 0.5→0, 0.75→1081, 1.0→45, +Inf→0.
> Reproduction: https://github.com/mohiadeen-ameer/opensearch-prometheus-lab (`curl "localhost:8081/chaos?latency_ms=700&error_rate=0.25"`).
> Expected: cumulative buckets (each `le` includes all smaller ones, `+Inf` = count).
