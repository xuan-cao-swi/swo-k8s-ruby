# Tail Sampling Example (minikube, swo-k8s-collector Helm chart)

This guide builds everything from scratch on your laptop: a new minikube cluster, the SolarWinds swo-k8s-collector Helm chart from helm.solarwinds.com with tail sampling enabled on its gateway, and a demo Rails app instrumented with `solarwinds_apm` that sends its traces through the gateway.

If you already have a cluster and a Ruby app, use `guide-with-existing-k8s-cluster` instead.

Every step is a plain `minikube` / `kubectl` / `helm` / `curl` command. No `make`, no scripts.

```
Rails app (rails-app/, solarwinds_apm)          namespace rails-demo
   │ OTLP/HTTP :4318
   ▼
swo-gateway Service ──▶ gateway pods (StatefulSet, 2 replicas)   ── logs, metrics ──▶ SWO
   │ traces/loadbalance: loadbalancing exporter routes by trace ID
   │ (through the headless Service swo-gateway-headless)
   ▼
gateway pod that owns the trace
   │ traces/tailsampling: tail_sampling processor
   └── sampled traces ──────────────────────────────────────────────────────▶ SWO
```

Files in this folder:

| File | What it is |
|------|------------|
| `rails-app/` | Rails 8.1 API app with `solarwinds_apm`, built into an image inside minikube |
| `k8s/rails-app.yaml` | Deployment + Service for the Rails app |
| `k8s/loadgen.yaml` | In-cluster curl loop that keeps traffic flowing |
| `helm/values-minikube.yaml` | Chart overrides for a single small node (resources, 2 gateway replicas, container logs) |
| `helm/values-tail-sampling.yaml` | Tail sampling on, with policies tuned for the demo app |

Everything runs on a **dedicated minikube profile `swo-demo`**, so an existing `minikube` cluster is never touched. Every command pins the cluster explicitly:

- `minikube -p swo-demo ...`
- `kubectl --context swo-demo ...`
- `helm --kube-context swo-demo ...`

Run all commands from this folder (`/Users/Xuan.Cao/Desktop/swo-k8s-ruby`).

## 0. Prerequisites

Docker Desktop (≥ 4 CPU / 8 GB free), minikube, kubectl, helm, openssl.

```sh
brew install minikube kubectl helm
docker info >/dev/null && echo "docker ok"
minikube profile list            # existing profiles; none of them will be modified
kubectl config current-context   # stays unchanged throughout this guide
```

You also need:

- A SolarWinds Observability **ingestion API token** (for the collector).
- An **APM service key** `<api-token>:<service-name>` (for the Rails agent). The part after the colon is the service name shown in SWO APM.
- Your data center, e.g. `na-01`.

Set these in the terminal. Every later step reads them, so re-export them if you open a new terminal.

```sh
export SWO_API_TOKEN=<your-ingestion-token>
export SW_APM_SERVICE_KEY=<your-api-token>:rails-tail-sampling
export SWO_REGION=na-01                                   # na-01 | na-02 | eu-01 | ap-01
export SWO_OTEL_ENDPOINT=otel.collector.$SWO_REGION.cloud.solarwinds.com:443
export SW_APM_COLLECTOR=apm.collector.$SWO_REGION.cloud.solarwinds.com:443
export CLUSTER_NAME=swo-demo-minikube                     # how the cluster is named in SWO
```

## 1. Start a Separate minikube Cluster

```sh
minikube start -p swo-demo \
  --driver=docker \
  --cpus=4 --memory=8192 --disk-size=30g \
  --keep-context=true \
  --addons=metrics-server
```

What this does:

- `-p swo-demo` creates a separate cluster with its own Docker container, network and kube context.
- `--cpus/--memory/--disk-size` leave room for the collector and two gateway pods. These sizes only apply when the profile is first created.
- `--keep-context=true` adds a `swo-demo` entry to `~/.kube/config` but doesn't make it the default. That's why every later command passes `--context swo-demo` or `--kube-context swo-demo`.
- `--addons=metrics-server` provides pod/node CPU and memory usage, which the collector can report.

Verify:

```sh
minikube profile list                  # "swo-demo" is listed
kubectl config current-context         # unchanged
kubectl --context swo-demo get nodes   # the new cluster, STATUS Ready
```

> Always pass `-p swo-demo` to minikube. Without it, `minikube stop/delete/image build` act on the **default** profile. Never run `minikube delete --all`.

## 2. Add the SolarWinds Helm Repository

```sh
helm repo add solarwinds https://helm.solarwinds.com
helm repo update
```

Tail sampling settings (`otel.gateway.tailSampling`) are available from chart 5.4.0, which is published as pre-release (`5.4.0-alpha.N`). Check what is available:

```sh
helm search repo solarwinds/swo-k8s-collector --devel --versions | head
export CHART_VERSION=5.4.0-alpha.7   # or a newer 5.4.x once released
```

Pre-release versions are not selected by default, so every `helm` command below passes `--version "$CHART_VERSION"`.

## 3. Install the Collector with Tail Sampling Enabled

### Namespace + API token Secret

```sh
kubectl --context swo-demo create namespace swo-collector
kubectl --context swo-demo -n swo-collector create secret generic solarwinds-api-token \
  --from-literal=SOLARWINDS_API_TOKEN="$SWO_API_TOKEN"
```

The chart reads the token from the Secret `solarwinds-api-token`, which keeps it out of the Helm values.

### Values files

Two values files are layered; later files win:

1. `helm/values-minikube.yaml`: fits the chart on one small node.
   - container logs on, so the Rails logs (with trace IDs) appear next to its traces;
   - the gateway requests 200m CPU instead of a full core, and is fixed at **2 replicas** so the loadbalancing exporter really routes traces between two pods;
   - network topology (eBPF) off, because the Docker Desktop VM doesn't reliably support it.
2. `helm/values-tail-sampling.yaml`: turns tail sampling on and replaces the default policies with ones tuned for the demo app (see [Policies](#policies)).

Optionally render the chart first to check the generated gateway config; this does not touch the cluster:

```sh
helm template swo-k8s-collector solarwinds/swo-k8s-collector --version "$CHART_VERSION" -n swo-collector \
  -f helm/values-minikube.yaml -f helm/values-tail-sampling.yaml \
  --set-string otel.endpoint="$SWO_OTEL_ENDPOINT" \
  --set-string cluster.name="$CLUSTER_NAME" \
  | grep -A80 '  tail_sampling:'
```

### Install

```sh
helm --kube-context swo-demo upgrade --install swo-k8s-collector solarwinds/swo-k8s-collector \
  --version "$CHART_VERSION" \
  --namespace swo-collector \
  -f helm/values-minikube.yaml \
  -f helm/values-tail-sampling.yaml \
  --set-string otel.endpoint="$SWO_OTEL_ENDPOINT" \
  --set-string cluster.name="$CLUSTER_NAME" \
  --wait --timeout 10m
```

`upgrade --install` installs the first time and upgrades on later runs, so it is safe to re-run after every values change.

Verify:

```sh
kubectl --context swo-demo -n swo-collector get pods
# swo-k8s-collector-gateway-0, -gateway-1, -node-collector-*, -metrics-*, -events-0, -kube-state-metrics-* -> Running
kubectl --context swo-demo -n swo-collector get svc swo-gateway swo-gateway-headless
```

| Pod | What it does |
|-----|--------------|
| `gateway-0`, `gateway-1` (StatefulSet) | Takes in OTLP from apps; routes traces by trace ID, tail-samples them, forwards to SWO |
| `node-collector` (one per node) | Container logs and node/pod metrics |
| `metrics` | Scrapes Prometheus-style metrics |
| `events` | Kubernetes events |
| `kube-state-metrics` | State of Kubernetes objects |

The Service `swo-gateway` is the OTLP entry point for apps. The headless Service `swo-gateway-headless` lets the loadbalancing exporter find the individual gateway pods.

## 4. Build the Rails App Image

Build straight into the `swo-demo` node, so no registry is needed. `k8s/rails-app.yaml` uses `imagePullPolicy: Never` ("use the local image, never download it").

```sh
minikube -p swo-demo image build -t rails-swo-demo:local rails-app/
minikube -p swo-demo image ls | grep rails-swo-demo   # verify
```

About the app (`rails-app/`):

- Rails 8.1 API-only, Puma, SQLite (the DB is created on start by `bin/docker-entrypoint`).
- `solarwinds_apm` is the last gem in the `Gemfile`, so it loads after the libraries it instruments.
- `config/initializers/solarwinds_apm.rb` adds trace IDs to log lines. `/health` is traced on purpose, so the gateway's `healthcheck-policy` has something to drop.
- Endpoints:

| Endpoint | What it produces |
|----------|------------------|
| `GET /` | info, and `apm_ready` (whether `solarwinds_apm` is ready) |
| `GET /items`, `POST /items` | ActiveRecord spans |
| `GET /slow` | custom spans, random 0.1–1.5 s latency, custom metric |
| `GET /external` | outbound Net::HTTP span |
| `GET /error` | exception, 500, error span |
| `GET /trace` | current trace context |
| `GET /health` | health check (kube probes) |

## 5. Deploy the Rails App, Pointed at the Gateway

### Namespace, Secret, ConfigMap

```sh
kubectl --context swo-demo create namespace rails-demo

kubectl --context swo-demo -n rails-demo create secret generic swo-apm \
  --from-literal=SW_APM_SERVICE_KEY="$SW_APM_SERVICE_KEY" \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -hex 64)"

kubectl --context swo-demo -n rails-demo create configmap rails-swo-demo-config \
  --from-literal=SW_APM_COLLECTOR="$SW_APM_COLLECTOR" \
  --from-literal=SW_APM_DEBUG_LEVEL=3 \
  --from-literal=OTEL_SERVICE_NAME=rails-swo-demo \
  --from-literal=RAILS_LOG_LEVEL=info \
  --from-literal=OTEL_EXPORTER_OTLP_ENDPOINT=http://swo-gateway.swo-collector.svc.cluster.local:4318
```

What these settings do:

- `SW_APM_SERVICE_KEY` (Secret) authenticates the agent; `SECRET_KEY_BASE` is needed for Rails production mode.
- `OTEL_EXPORTER_OTLP_ENDPOINT` is what sends the app's traces, metrics and logs to the gateway. **Without it, `solarwinds_apm` exports straight to SWO and no trace goes through tail sampling.** The app is in another namespace, so use the full service DNS name.
- `SW_APM_COLLECTOR` is still needed: the agent fetches its head-sampling settings from `apm.collector.<region>...`.
- Don't set `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (or `_METRICS_` / `_LOGS_`): a per-signal variable wins over the general one, and that signal would bypass the gateway.

### Deployment + Service

```sh
kubectl --context swo-demo -n rails-demo apply -f k8s/rails-app.yaml
kubectl --context swo-demo -n rails-demo rollout status deployment/rails-swo-demo --timeout=5m
kubectl --context swo-demo -n rails-demo exec deploy/rails-swo-demo -- printenv OTEL_EXPORTER_OTLP_ENDPOINT
```

- The **Deployment** runs one Rails pod on port 3000 and loads the ConfigMap and Secret with `envFrom`. It passes the pod's name, namespace and UID (`SW_K8S_POD_*`), which lets SWO link the APM service to the Kubernetes pod and cluster. The probes call `/health`.
- The **Service** exposes the pod in the cluster as `rails-swo-demo:80`.

## 6. Send Traffic

```sh
kubectl --context swo-demo -n rails-demo port-forward svc/rails-swo-demo 3000:80
```

In a separate terminal:

```sh
curl 127.0.0.1:3000/          # "apm_ready":true expected
curl 127.0.0.1:3000/items
curl 127.0.0.1:3000/slow
curl 127.0.0.1:3000/external
curl 127.0.0.1:3000/error
curl 127.0.0.1:3000/trace
```

Continuous in-cluster traffic: `k8s/loadgen.yaml` calls `/`, `/items`, `/slow` and `POST /items` about every 2 seconds, plus `/external` every 5th round and `/error` every 10th.

```sh
kubectl --context swo-demo -n rails-demo apply -f k8s/loadgen.yaml
kubectl --context swo-demo -n rails-demo logs -f deploy/rails-swo-demo-loadgen
```

Check the agent:

```sh
kubectl --context swo-demo -n rails-demo logs -f deploy/rails-swo-demo
# request log lines carry trace_id=... trace_flags=01
```

`trace_flags=01` means the agent sampled the request and exports it. Head sampling happens first: tail sampling can only drop more of those traces, never bring back ones the agent didn't send.

## 7. Verify Tail Sampling

### Config is live

```sh
kubectl --context swo-demo -n swo-collector get pods -l app=swo-k8s-collector-gateway
kubectl --context swo-demo -n swo-collector get configmap swo-k8s-collector-gateway-config \
  -o jsonpath='{.data.gateway\.config}' | grep -A80 '  tail_sampling:'
```

If nothing prints, tail sampling is off.

### Policies are making decisions

Let the loadgen run for longer than `decision_wait` (10s), then read a gateway pod's own metrics:

```sh
kubectl --context swo-demo -n swo-collector port-forward pod/swo-k8s-collector-gateway-0 8888:8888
# separate terminal:
curl -s localhost:8888/metrics | grep tail_sampling
```

Repeat with `pod/swo-k8s-collector-gateway-1`: both pods should show decisions, which means the loadbalancing exporter is splitting traces between them. Look for:

- `otelcol_processor_tail_sampling_count_traces_sampled{policy="...",sampled="true|false"}`: per-policy decisions;
- `otelcol_processor_tail_sampling_global_count_traces_sampled`: final keep/drop counts;
- `otelcol_processor_tail_sampling_sampling_trace_dropped_too_early`: should stay 0. If it climbs, raise `num_traces`.

### In SolarWinds Observability

Data can take a couple of minutes to show up.

- **Kubernetes → Clusters → `swo-demo-minikube`** (from the collector)
- **APM → Services → `rails-tail-sampling`** (the service name from `SW_APM_SERVICE_KEY`)

Expect:

- every `/error` trace;
- `/slow` traces longer than 1 s;
- about half of `/items` (GET and POST);
- about 10% of everything else (`/`, fast `/slow`, `/external`);
- no `/health` traces;
- traces appear about `decision_wait` (10s) later than with direct export;
- with `recordPolicy: true`, sampled spans carry an attribute naming the policy that sampled them.

## Policies

`helm/values-tail-sampling.yaml` replaces the chart's default list with:

| Policy | Type | Effect |
|--------|------|--------|
| `healthcheck-policy` | `drop` | drops traces whose `url.path` matches `/health.*` |
| `error-policy` | `status_code` | keeps every trace with an `ERROR` span |
| `high-latency-policy` | `latency` | keeps every trace longer than 1000 ms (chart default: 5000) |
| `trigger-trace-policy` | `boolean_attribute` | keeps trigger-traced requests (`TriggeredTrace=true`, set by `solarwinds_apm`) |
| `items-policy` | `and` | keeps 50% of traces whose `url.path` starts with `/items` |
| `fallback-policy` | `probabilistic` | keeps 10% of everything else (chart default: 1%) |

A trace is sampled if any policy samples it, a matching drop policy always wins, and a trace that matches no policy is not sampled. Keep a fallback policy at the end.

To see the chart defaults and what the release currently uses:

```sh
helm show values solarwinds/swo-k8s-collector --version "$CHART_VERSION" | sed -n '/^    tailSampling:/,/^cluster:/p'
helm --kube-context swo-demo -n swo-collector get values swo-k8s-collector --all | sed -n '/^    tailSampling:/,/^[a-z]/p'
```

### Changing policies

> **Helm replaces lists, it doesn't merge them.** Setting `policies:` replaces the whole list. Copy every policy you want to keep, including the fallback.

Edit `helm/values-tail-sampling.yaml`, then re-run the same `helm upgrade --install` from step 3. The gateway pods roll automatically (the pod template carries a checksum of the rendered config); the Rails app doesn't need a restart.

Notes:

- **Attribute names:** the Ruby OpenTelemetry instrumentation emits the stable HTTP names: `url.path` (e.g. `/items/42`), `http.request.method`, `http.response.status_code`. Rails also sets `http.route` to the route pattern, e.g. `/items/:id`. The legacy `http.target` / `http.method` won't match.
- **Policy types:** every type of the `tail_sampling` processor works (`numeric_attribute`, `rate_limiting`, `span_count`, `ottl_condition`, `composite`, ...). See the [processor README](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor).
- **Buffer size:** `num_traces` (default 10000) should be at least `expected_new_traces_per_sec` (default 500) × `decision_wait` seconds. The demo's load is far below this.
- **Quick experiment:** to compare against no tail sampling, append `--set otel.gateway.tailSampling.enabled=false` to the install command; the app keeps sending to `swo-gateway` and traces are exported unchanged.

## 8. Iterating on Changes

Changed Rails code:

```sh
minikube -p swo-demo image build -t rails-swo-demo:local rails-app/
kubectl --context swo-demo -n rails-demo rollout restart deployment/rails-swo-demo
```

The tag stays `rails-swo-demo:local`, so the restart is what picks up the new image.

Changed app config (pods only read `envFrom` values at start):

```sh
kubectl --context swo-demo -n rails-demo delete configmap rails-swo-demo-config
# ... re-create it with the command from step 5, e.g. SW_APM_DEBUG_LEVEL=5 for verbose agent logs
kubectl --context swo-demo -n rails-demo rollout restart deployment/rails-swo-demo
```

Changed `k8s/rails-app.yaml`:

```sh
kubectl --context swo-demo -n rails-demo apply -f k8s/rails-app.yaml
kubectl --context swo-demo -n rails-demo rollout status deployment/rails-swo-demo
```

Changed collector values or chart version: update `CHART_VERSION` or the values files, then re-run the `helm upgrade --install` from step 3.

After a laptop restart:

```sh
minikube start -p swo-demo
kubectl --context swo-demo get pods -A
```

## 9. Clean Up

From least to most destructive:

```sh
# stop the load generator only
kubectl --context swo-demo -n rails-demo delete -f k8s/loadgen.yaml

# remove app + collector, keep the cluster
kubectl --context swo-demo delete namespace rails-demo
helm --kube-context swo-demo -n swo-collector uninstall swo-k8s-collector
kubectl --context swo-demo delete namespace swo-collector

# stop / delete only this profile (other profiles untouched)
minikube -p swo-demo stop
minikube -p swo-demo delete
```

## More Information

Consult the `tail_sampling` processor and `loadbalancing` exporter documentation before production use, and size the gateway resources and replicas for your trace volume. See also the SolarWinds Observability documentation on tail sampling support.
