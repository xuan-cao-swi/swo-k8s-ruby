# solarwinds_apm configuration. Loaded by the gem from config/initializers/solarwinds_apm.rb.
# Environment variables (SW_APM_*) take precedence over these values.
# Full reference: https://github.com/solarwinds/apm-ruby/blob/main/CONFIGURATION.md
if defined?(SolarWindsAPM::Config)
  # The service key comes from SW_APM_SERVICE_KEY (Kubernetes Secret "swo-apm").

  # Add trace context (trace_id, span_id, ...) to Rails log lines so container
  # logs shipped by swo-k8s-collector can be correlated with traces.
  SolarWindsAPM::Config[:log_traceId] = :traced

  # The /health probe is traced here on purpose: the swo-k8s-collector gateway's
  # tail-sampling healthcheck-policy drops it (see guide-with-minikube-cluster.md).
end
