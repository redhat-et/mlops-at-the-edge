# Bootc OS Image for FlightCtl-Managed GPU Devices

RHEL 10 bootc image for AWS EC2 g5.xlarge instances with NVIDIA A10G GPU support, FlightCtl agent, and Podman runtime.

**Current Version:** v1.0.21
**Registry:** `quay.io/redhat-et/mlops-bootc-rhel10-nvidia`

---

## What's Included

| Component | Details |
|-----------|---------|
| **OS** | RHEL 10 bootc |
| **NVIDIA Drivers** | Pre-compiled open kernel modules from RHEL extensions repo |
| **FlightCtl Agent** | Late binding (enrollment cert injected via cloud-init at launch) |
| **Container Runtime** | Podman + podman-compose + nvidia-container-toolkit |
| **Observability** | Node Exporter (port 9100) + OpenTelemetry Collector |
| **Cloud-Init** | EC2 user-data processing for NVMe storage and FlightCtl enrollment |

---

## How It Fits Together

```
Containerfile.bootc + configs/
    ↓ podman build (on x86_64 build instance)
OCI image → quay.io/redhat-et/mlops-bootc-rhel10-nvidia:v1.0.21
    ↓ bootc-image-builder --type ami
disk.raw → EBS volume → snapshot → AMI
    ↓ deploy.sh (aws/ folder)
EC2 g5.xlarge instances boot from AMI
    ↓ cloud-init injects FlightCtl enrollment cert
FlightCtl agent connects → fleet.yaml pushes 3-container app stack
```

This image is the **OS only**. The application (model-car, vLLM, OpenWebUI) is defined inline in `aws/fleet.yaml` and deployed by FlightCtl after the device enrolls.

---

## Building the Image

### Prerequisites

- x86_64 Linux machine (or AWS build instance — cannot build on Mac)
- Podman 5.0+
- Red Hat subscription with access to RHEL 10 extensions and supplementary repos (for NVIDIA packages)
- `podman login registry.redhat.io` (for the base image)

### 1. Build OCI Image

The NVIDIA driver installation requires Red Hat Subscription Manager (RHSM) credentials, passed as build secrets so they are not baked into the image layers.

```bash
export VERSION=v1.0.21
export OCI_IMAGE_REPO=quay.io/redhat-et/mlops-bootc-rhel10-nvidia

cd scenarios/scenario-01-device-edge/bootc-image

# Create credential files (these are .gitignored)
echo "your-rh-username" > rhsm_user
echo 'your-rh-password' > rhsm_pass

sudo podman build --platform=linux/amd64 \
  --secret id=rhsm_user,src=$(pwd)/rhsm_user \
  --secret id=rhsm_pass,src=$(pwd)/rhsm_pass \
  -f containerfiles/Containerfile.bootc \
  -t ${OCI_IMAGE_REPO}:${VERSION} .

# Clean up credentials
rm rhsm_user rhsm_pass
```

### 2. Push to Quay

```bash
sudo podman login quay.io
sudo podman push ${OCI_IMAGE_REPO}:${VERSION}
```

### 3. Convert to AMI

Run the helper script to create an AMI. Pass the container image and AWS region:

```bash
./aws/scripts/build-ami.sh ${OCI_IMAGE_REPO}:${VERSION} eu-north-1
```

#### Alternative: Manual Approach

Launch a temporary t3.xlarge RHEL 9 build instance, then:

```bash
# On the build instance
sudo podman pull ${OCI_IMAGE_REPO}:${VERSION}

mkdir -p ~/bootc-build/output && cd ~/bootc-build

sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v "${PWD}/output":/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type ami \
  ${OCI_IMAGE_REPO}:${VERSION}
```

Then create a 50GB EBS volume, `dd` the disk.raw to it, create a snapshot, and register the AMI with UEFI boot mode. See the manual AMI build steps in the project notes for full details.

---

## Files

```
containerfiles/
├── Containerfile.bootc                  # OS image definition
├── README.bootc.md                      # This file
└── configs/
    ├── 01-configure-otel-certs.conf     # OTel Collector systemd drop-in for TLS certs
    ├── containers.conf                  # Podman capabilities for GPU workloads
    ├── flightctl-cert-config.yaml       # FlightCtl cert config for OTel
    ├── node_exporter.service            # Prometheus node_exporter systemd unit
    ├── nvidia-cdi-generate.service      # First-boot: generates /etc/cdi/nvidia.yaml
    ├── nvidia-uvm-init.service          # Boot: creates /dev/nvidia-uvm device nodes
    ├── otel-reload-lifecyclehook.yaml   # FlightCtl lifecycle hook to reload OTel
    └── otelcol-config.yaml              # OpenTelemetry Collector base config
```

---

## SELinux and GPU Containers

GPU containers typically require `--security-opt=label=disable` to bypass SELinux label enforcement for device access. This image eliminates that workaround using two changes:

1. **`container_use_devices` boolean** (baked into image) - allows containers to access GPU devices via CDI while SELinux remains enforced
2. **`:z` shared volume labels** (set in fleet.yaml compose) - uses lowercase `:z` instead of `:Z` on shared volumes so multiple containers (model-car and vLLM) can both access the `model-storage` volume under SELinux

This means vLLM runs with full SELinux confinement - no security exceptions required.

```bash
# Verify the boolean is set
getsebool container_use_devices
# Expected: container_use_devices --> on
```

---

## Verification (on a booted EC2 instance)

```bash
# GPU detected
nvidia-smi

# CDI config generated
ls /etc/cdi/nvidia.yaml

# FlightCtl agent running
sudo systemctl status flightctl-agent

# Node Exporter running
sudo systemctl status node_exporter

# OTel Collector running
sudo systemctl status opentelemetry-collector

# SELinux GPU access enabled
getsebool container_use_devices

# GPU passthrough works
sudo podman run --rm --device nvidia.com/gpu=all \
  docker.io/nvidia/cuda:12.0.0-base-ubi8 nvidia-smi
```
