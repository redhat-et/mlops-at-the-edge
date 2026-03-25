"""KFP v2 Inner Loop Pipeline - Model Refresh from Edge Metrics.

Simulates the inner loop of the MLOps feedback cycle:
  Edge alert -> log context -> simulate retraining -> register model -> trigger outer loop

Compile: python pipeline.py
Upload:  pipeline.yaml to RHOAI Dashboard -> Data Science Pipelines -> Import
"""

import time
from datetime import datetime, timezone

from kfp import compiler, dsl

PIPELINE_IMAGE = "registry.access.redhat.com/ubi9/python-311:latest"


@dsl.component(base_image=PIPELINE_IMAGE)
def log_alert(alert_name: str, severity: str, device_id: str) -> str:
    """Log the incoming alert context that triggered this pipeline run."""
    print("=" * 60)
    print("ALERT RECEIVED")
    print("=" * 60)
    print(f"  Alert:    {alert_name}")
    print(f"  Severity: {severity}")
    print(f"  Device:   {device_id}")
    print("=" * 60)

    context = f"alert={alert_name} severity={severity} device={device_id}"
    print(f"Trigger context: {context}")
    return context


@dsl.component(base_image=PIPELINE_IMAGE)
def simulate_retraining(trigger_context: str) -> str:
    """Simulate model retraining with fake training loop.

    Runs 5 epochs with decreasing loss and increasing accuracy.
    Generates a version tag based on today's date.
    """
    import time
    from datetime import datetime, timezone

    print(f"Starting retraining triggered by: {trigger_context}")
    print("-" * 60)

    # Simulate 5 training epochs
    for epoch in range(1, 6):
        loss = 2.5 / (epoch + 0.5)
        accuracy = min(0.60 + epoch * 0.07, 0.95)
        print(f"Epoch {epoch}/5 - loss: {loss:.4f} - accuracy: {accuracy:.4f}")
        time.sleep(5)

    version = "v1.0." + datetime.now(timezone.utc).strftime("%Y%m%d%H%M")
    print("-" * 60)
    print(f"Training complete. Model version: {version}")
    return version


@dsl.component(base_image=PIPELINE_IMAGE)
def register_model(model_version: str) -> str:
    """Mock model registration (log only, no registry API calls)."""
    model_name = "llama-3.2-1b"
    artifact_uri = f"quay.io/redhat-et/modelcar-{model_name}:{model_version}"

    print("=" * 60)
    print("MODEL REGISTRATION (mock)")
    print("=" * 60)
    print(f"  Model:    {model_name}")
    print(f"  Version:  {model_version}")
    print(f"  Artifact: {artifact_uri}")
    print(f"  Status:   REGISTERED")
    print("=" * 60)

    return model_version


@dsl.component(
    base_image=PIPELINE_IMAGE,
    packages_to_install=["requests"],
)
def trigger_outer_loop(model_version: str, github_token: str, flightctl_url: str) -> str:
    """Trigger the GitHub Actions model-refresh-build workflow via workflow_dispatch."""
    import requests

    repo = "redhat-et/mlops-at-the-edge"
    workflow = "model-refresh-build.yaml"
    url = f"https://api.github.com/repos/{repo}/actions/workflows/{workflow}/dispatches"

    payload = {
        "ref": "main",
        "inputs": {
            "model_version": model_version,
            "trigger": "kfp-inner-loop",
            "flightctl_url": flightctl_url,
        },
    }

    headers = {
        "Accept": "application/vnd.github.v3+json",
        "Authorization": f"Bearer {github_token}",
    }

    print(f"Triggering outer loop: {url}")
    print(f"  ref: main")
    print(f"  model_version: {model_version}")
    print(f"  flightctl_url: {flightctl_url}")

    resp = requests.post(url, json=payload, headers=headers, timeout=30)

    if resp.status_code == 204:
        print("Outer loop triggered successfully (HTTP 204)")
        return f"triggered:{model_version}"
    else:
        msg = f"Failed to trigger outer loop: HTTP {resp.status_code} - {resp.text}"
        print(msg)
        raise RuntimeError(msg)


@dsl.pipeline(
    name="mlops-inner-loop",
    description="Inner loop: respond to edge alert by retraining and triggering outer loop deployment.",
)
def inner_loop_pipeline(
    github_token: str,
    flightctl_url: str,
    alert_name: str = "VLLMHighLatency",
    severity: str = "warning",
    device_id: str = "unknown",
):
    log_task = log_alert(
        alert_name=alert_name,
        severity=severity,
        device_id=device_id,
    )
    log_task.set_caching_options(False)

    retrain_task = simulate_retraining(
        trigger_context=log_task.output,
    )
    retrain_task.set_caching_options(False)

    register_task = register_model(
        model_version=retrain_task.output,
    )
    register_task.set_caching_options(False)

    trigger_task = trigger_outer_loop(
        model_version=register_task.output,
        github_token=github_token,
        flightctl_url=flightctl_url,
    )
    trigger_task.set_caching_options(False)


if __name__ == "__main__":
    compiler.Compiler().compile(
        pipeline_func=inner_loop_pipeline,
        package_path="pipeline.yaml",
    )
    print("Compiled pipeline.yaml")
