# Bootc OS Image for FlightCtl-Managed GPU Devices

RHEL 10 bootc image for AWS EC2 g5.xlarge instances with NVIDIA A10G GPU support, FlightCtl agent, and Podman runtime.

**Current Version:** v1.0.8
**AMI:** ami-03801f728fb544522 (eu-north-1)

---

## What's Included

| Component | Details |
|-----------|---------|
| **OS** | RHEL 10 bootc |
| **NVIDIA Drivers** | 590.48.01 + CUDA 13.1 (DKMS compiled at build time) |
| **FlightCtl Agent** | Late binding (enrollment cert injected via cloud-init at launch) |
| **Container Runtime** | Podman + podman-compose + nvidia-container-toolkit |
| **Observability** | OpenTelemetry Collector (enabled), Node Exporter (installed, disabled) |
| **Cloud-Init** | EC2 user-data processing for NVMe storage and FlightCtl enrollment |

---

## How It Fits Together

```
Containerfile.bootc + configs/
    ↓ podman build (on x86_64 build instance)
OCI image → quay.io/redhat-et/mlops-bootc-rhel10-nvidia:v1.0.8
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

- x86_64 Linux machine (or AWS build instance - cannot build on Mac)
- Podman 5.0+
- Red Hat subscription (`podman login registry.redhat.io`)

### 1. Build OCI Image

```bash
export VERSION=v1.0.8
export OCI_IMAGE_REPO=quay.io/redhat-et/mlops-bootc-rhel10-nvidia

cd scenarios/scenario-02-device-edge/bootc-image
sudo podman build --platform=linux/amd64 \
  -f containerfiles/Containerfile.bootc \
  -t ${OCI_IMAGE_REPO}:${VERSION} .
```

**Build time:** ~15-20 minutes (includes NVIDIA DKMS compilation)

### 2. Push to Quay

```bash
sudo podman login quay.io
sudo podman push ${OCI_IMAGE_REPO}:${VERSION}
```

### 3. Convert to AMI

Launch a temporary t3.xlarge RHEL 9 build instance in eu-north-1, then:

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
├── Containerfile.bootc                # OS image definition
├── README.bootc.md                    # This file
└── configs/
    ├── containers.conf                # Podman capabilities for GPU workloads
    └── nvidia-cdi-generate.service    # First-boot systemd service: generates
                                       # /etc/cdi/nvidia.yaml for GPU passthrough
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

# OTel Collector running
sudo systemctl status otelcol

# GPU passthrough works
sudo podman run --rm --device nvidia.com/gpu=all \
  docker.io/nvidia/cuda:12.0.0-base-ubi8 nvidia-smi
```

---

