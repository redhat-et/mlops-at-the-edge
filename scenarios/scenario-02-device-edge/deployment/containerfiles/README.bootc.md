# Bootc OS Image for FlightCtl-Managed GPU Devices

RHEL 10 bootc image for AWS EC2 g5.xlarge instances with NVIDIA A10G GPU support, FlightCtl agent, and Podman runtime.

**Status:** ✅ v1.0.4 production-ready and tested

---

## What's Included

- **NVIDIA Drivers:** 590.48.01 + CUDA 13.1 (pre-compiled DKMS modules for kernel 6.12.0-201.el10)
- **FlightCtl Agent:** Early binding (enrollment cert baked into image)
- **Container Runtime:** Podman 5.0+ with nvidia-container-toolkit (CDI for GPU passthrough)
- **podman-compose:** Required for FlightCtl compose applications
- **Cloud-Init:** EC2 runtime config (NVMe storage, SSH keys)

---

## Quick Start

### Prerequisites

- Podman 5.0+
- FlightCtl CLI
- Red Hat subscription (for pulling base image)

### 1. Generate FlightCtl Enrollment Certificate

```bash
flightctl login <flightctl-url>
cd scenarios/scenario-02-device-edge/deployment
flightctl certificate request --signer=enrollment --expiration=365d --output=embedded > containerfiles/configs/flightctl-config.yaml
```

**⚠️ Security:** This file contains credentials - already in `.gitignore`, do NOT commit.

### 2. Build Bootc Image

```bash
export VERSION=v1.0.4
export OCI_IMAGE_REPO=quay.io/redhat-et/mlops-bootc-rhel10-nvidia

sudo podman login registry.redhat.io
sudo podman build --platform=linux/amd64 -f containerfiles/Containerfile.bootc -t ${OCI_IMAGE_REPO}:${VERSION} .
```

**Build time:** 15-20 minutes (includes DKMS compilation)
**Image size:** ~3.5-4 GB

### 3. Push to Registry

```bash
sudo podman login quay.io
sudo podman push ${OCI_IMAGE_REPO}:${VERSION}
```

### 4. Convert to AWS AMI

```bash
mkdir -p output
sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v "${PWD}/output":/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type ami \
  ${OCI_IMAGE_REPO}:${VERSION}
```

**Output:** `output/ami/disk.raw` (~10-12 GB)
**Upload to AWS:** See [AWS import docs](https://docs.aws.amazon.com/vm-import/latest/userguide/vmimport-image-import.html) or use AWS Console

---

## Verification

### On EC2 Instance (after boot)

```bash
# Check GPU
nvidia-smi  # Should show NVIDIA A10G

# Check kernel modules
lsmod | grep nvidia  # Should show nvidia, nvidia_uvm, nvidia_modeset, nvidia_drm

# Check CDI config
ls /etc/cdi/nvidia.yaml  # Should exist

# Test GPU passthrough
sudo podman run --rm --device nvidia.com/gpu=all docker.io/nvidia/cuda:12.0.0-base-ubi8 nvidia-smi
```

### On FlightCtl Control Plane

```bash
flightctl get enrollmentrequests  # Device should appear
flightctl approve -l role=gpu-inference enrollmentrequest/<device-name>
flightctl get devices  # Device status should be "Online"
```

---

## Key Design Decisions

### NVIDIA Drivers: Build Time vs Runtime

**Chosen:** Build time (DKMS modules compiled during image build)

**Why:**

- Bootc `/lib/modules` is read-only - runtime installation fails
- Build kernel = boot kernel (unlike containers)
- Faster boot (2-3 min vs 5-7 min)
- Production-ready golden image approach

**Challenges overcome:**

1. OpenSSL FIPS conflict → `dnf swap openssl-fips-provider-so openssl-libs`
2. Build host kernel mismatch → Query from RPM: `$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')`
3. X11/GL dependencies → Install from CentOS Stream 10 (~100MB overhead)
4. DKMS registration → Explicit `dkms build -k ${KERNEL_VERSION}`

### FlightCtl: Early Binding

**Chosen:** Enrollment cert baked into image (all devices auto-enroll to same FlightCtl instance)

**Why:** Simpler for MVP, no cloud-init cert injection complexity

**Trade-off:** Image tied to specific FlightCtl instance (acceptable for testing)

---

## Files Structure

```
containerfiles/
├── Containerfile.bootc          # OS image (this file)
├── Containerfile.compose         # App manifest packaging (separate workflow)
├── configs/
│   ├── flightctl-config.yaml    # Enrollment cert (DO NOT COMMIT)
│   ├── nvidia-cdi-generate.service  # First-boot CDI generation
│   └── containers.conf          # Podman capabilities
└── README.bootc.md              # This file
```

---

## Troubleshooting

**Build fails:** `Failed to pull registry.redhat.io/rhel10/rhel-bootc`
→ Authenticate: `sudo podman login registry.redhat.io`

**nvidia-smi not found:**
→ Check drivers installed: `rpm -qa | grep nvidia-driver`

**nvidia-smi fails: "Failed to communicate with driver":**
→ Check modules: `lsmod | grep nvidia`, try `sudo modprobe nvidia`

**CDI missing** (`/etc/cdi/nvidia.yaml`):
→ Check service: `sudo systemctl status nvidia-cdi-generate.service`

**FlightCtl agent not connecting:**
→ Verify `/etc/flightctl/config.yaml` exists (baked into image)

---

## References

- [CLAUDE.md Section 8](../../../CLAUDE.md#8-flightctl-managed-ec2-gpu-deployment-reference) - Manual EC2 GPU setup (systemd-based)
- [FlightCtl: Building OS Images](https://github.com/flightctl/flightctl/blob/main/docs/user/building/building-images.md)
- [FlightCtl: Managing Applications](https://github.com/flightctl/flightctl/blob/main/docs/user/using/managing-devices.md#managing-applications)
- [Bootc Project](https://bootc.dev/)

---

**Next:** Deploy applications via FlightCtl compose (see CLAUDE.md Section 9)
