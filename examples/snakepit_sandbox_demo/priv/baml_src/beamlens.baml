// BeamLens BAML definitions
// Note: This placeholder client is overridden at runtime via client_registry

// Default retry policy - reference as "DefaultRetry" in client_registry
retry_policy DefaultRetry {
  max_retries 3
  strategy {
    type exponential_backoff
    delay_ms 200
    multiplier 1.5
    max_delay_ms 10000
  }
}

client<llm> Default {
  provider anthropic
  options {
    model "claude-haiku-4-5-20251001"
  }
}
