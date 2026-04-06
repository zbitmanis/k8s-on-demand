# Monitoring — Prometheus & Thanos

## Architecture

| Component | Role | Location | Namespace |
|---|---|---|---|
| **Prometheus** | Single instance scrapes all tenant namespaces | Shared cluster | `monitoring` |
| **Thanos Sidecar** | Uploads 2h TSDB blocks to S3 | Shared cluster (sidecar to Prom) | `monitoring` |
| **Thanos Store Gateway** | Reads S3 blocks, serves gRPC | Management cluster | `monitoring` |
| **Thanos Query** | Federates live + historical | Management cluster | `monitoring` |
| **Thanos Compactor** | Downsamples + cleanup | Management cluster | `monitoring` |
| **Grafana** | Dashboard UI (OIDC auth) | Management cluster | `monitoring` |

**Metrics bucket:** `k8s-od-thanos-metrics` (survives cluster destroy)

## Prometheus Configuration

**Key settings:**
- `retention: 2h` — short local retention (Thanos handles long-term)
- `serviceMonitorSelectorNilUsesHelmValues: false` — scrape ALL namespaces
- **Sidecar IRSA role:** `<cluster>-thanos-sidecar` SA: `prometheus-kube-prometheus-prometheus`
- **Sidecar uploader:** runs as `prometheus` SA in `monitoring` namespace; publishes blocks to S3

**Metric labels:**
- Every metric includes `namespace` label — set during scrape config `relabel_configs`
- Example: `http_requests_total{namespace="acme-corp", pod="api-1", ...}`
- Grafana + Thanos queries filter by `{namespace="<tenant-id>"}` for per-tenant isolation

## Thanos Components

| Component | Purpose | IRSA Role |
|---|---|---|
| **Sidecar** (in Prom pod) | Upload blocks to S3 | `<cluster>-thanos-sidecar` |
| **Store Gateway** | Read S3 blocks | `<cluster>-thanos-sidecar` (shared) |
| **Compactor** | Downsampling + deletion | `<cluster>-thanos-sidecar` (shared) |
| **Query** | Federate Prom + Store | No AWS access |

**Store service account:** `thanos-sidecar-thanos` (from thanos-community/thanos v0.2.0)

**Downsampling:** Raw (40d) → 5m (10mo) → 1h (indefinite)

## Tenant Metrics Isolation

Three-layer isolation:
1. **Scrape-time:** `namespace` label applied at Prometheus scrape config
2. **Query-time:** Grafana dashboards and Thanos queries filtered by `{namespace="<tenant-id>"}`
3. **S3 structure:** Blocks organized by namespace prefix (namespace-aware segregation)

**Tenant alerting:**
- Tenants define `PrometheusRule` resources in their namespace
- Prometheus discovers all namespaces (no config change needed)
- Tenant rules are namespace-scoped (cannot reference other namespaces)

## Key Principles

1. **Single Prometheus instance** — cost-efficient, namespace-labeled metrics
2. **Thanos for long-term storage** — S3 blocks survive cluster destroy
3. **Bucket survives cluster destroy** — `k8s-od-thanos-metrics` not part of Terraform; lives outside cluster lifecycle
4. **IRSA scoping** — sidecar + store roles have S3 R/W on metrics bucket only; no other services need AWS credentials for metrics
5. **Bucket name is a GHA variable** — `THANOS_METRICS_BUCKET` (not secret)

*Full operator guide: see [`docs/monitoring.adoc`](monitoring.adoc)*
