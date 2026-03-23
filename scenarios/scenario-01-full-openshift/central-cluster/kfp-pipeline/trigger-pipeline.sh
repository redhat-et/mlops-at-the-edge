#!/usr/bin/env bash
# Trigger a KFP inner loop pipeline run from the command line.
#
# Usage:
#   ./trigger-pipeline.sh [ALERT_NAME] [SEVERITY] [DEVICE_ID]
#
# Defaults:
#   ALERT_NAME = VLLMHighLatency
#   SEVERITY   = warning
#   DEVICE_ID  = edge-001
#
# Prerequisites:
#   - oc login to the OpenShift cluster
#   - kfp Python package installed (pip install kfp)
#   - github-pat secret exists in mlops-kfp namespace
#   - DSPA deployed and pipeline uploaded

set -euo pipefail

NAMESPACE="mlops-kfp"
PIPELINE_NAME="mlops-inner-loop"

ALERT_NAME="${1:-VLLMHighLatency}"
SEVERITY="${2:-warning}"
DEVICE_ID="${3:-edge-001}"

echo "--- KFP Inner Loop Pipeline Trigger ---"
echo "  Alert:    ${ALERT_NAME}"
echo "  Severity: ${SEVERITY}"
echo "  Device:   ${DEVICE_ID}"
echo ""

# Get DS Pipelines API route
DSPA_ROUTE=$(oc get route -n "${NAMESPACE}" -l app=ds-pipeline-dspa -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
if [ -z "${DSPA_ROUTE}" ]; then
    echo "Error: Could not find DS Pipelines API route in namespace ${NAMESPACE}."
    echo "Make sure the DSPA is deployed: oc apply -f dspa.yaml"
    exit 1
fi

DSPA_URL="https://${DSPA_ROUTE}"
echo "DS Pipelines API: ${DSPA_URL}"

# Get OpenShift token for authentication
OC_TOKEN=$(oc whoami -t)
echo "Using token for user: $(oc whoami)"

# Read GitHub PAT from secret (if it exists)
GITHUB_TOKEN=$(oc get secret github-pat -n "${NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
if [ -z "${GITHUB_TOKEN}" ]; then
    echo ""
    echo "Warning: github-pat secret not found in ${NAMESPACE}."
    echo "The trigger_outer_loop step will fail without a valid GitHub token."
    echo "Create it with: oc create secret generic github-pat --from-literal=token=<PAT> -n ${NAMESPACE}"
    echo ""
    GITHUB_TOKEN="missing-create-github-pat-secret"
fi

echo ""
echo "Creating pipeline run..."

python3 - <<PYEOF
import sys
try:
    import kfp
except ImportError:
    print("Error: kfp package not installed. Run: pip install kfp")
    sys.exit(1)

client = kfp.Client(
    host="${DSPA_URL}",
    existing_token="${OC_TOKEN}",
    ssl_ca_cert=False,
)

# Find the pipeline by name
pipelines = client.list_pipelines(filter='{"predicates":[{"key":"name","op":"EQUALS","string_value":"${PIPELINE_NAME}"}]}')
if not pipelines.pipelines:
    print("Error: Pipeline '${PIPELINE_NAME}' not found. Upload pipeline.yaml first.")
    sys.exit(1)

pipeline_id = pipelines.pipelines[0].pipeline_id
print(f"Found pipeline: {pipeline_id}")

run = client.create_run_from_pipeline_id(
    pipeline_id=pipeline_id,
    experiment_name="mlops-inner-loop",
    run_name=f"inner-loop-{ALERT_NAME}-$(date +%Y%m%d-%H%M%S)",
    params={
        "alert_name": "${ALERT_NAME}",
        "severity": "${SEVERITY}",
        "device_id": "${DEVICE_ID}",
        "github_token": "${GITHUB_TOKEN}",
    },
)
print(f"Run created: {run.run_id}")
print(f"View in RHOAI Dashboard or: oc get pipelineruns -n ${NAMESPACE}")
PYEOF

echo ""
echo "Done."
