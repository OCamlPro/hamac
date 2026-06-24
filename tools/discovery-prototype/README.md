# SIESTE Infrastructure Discovery & Provisioning Prototype

Local prototype for testing PXE-based zero-touch infrastructure provisioning using QEMU/KVM.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Host Machine                                       │
│                                                                              │
│  ┌──────────────┐    ┌──────────────────┐    ┌──────────────┐              │
│  │   dnsmasq    │    │    Discovery     │    │    QEMU      │              │
│  │  DHCP/TFTP   │◄──►│     Server       │◄──►│     VMs      │              │
│  │  (port 67)   │    │   (port 8877)    │    │  (PXE boot)  │              │
│  └──────────────┘    │                  │    └──────────────┘              │
│         │            │  - /register     │           │                       │
│         │            │  - /nodes        │           │                       │
│         │            │  - /cloud-init   │           │                       │
│         │            │  - /images       │           │                       │
│         │            │  - /config       │           │                       │
│         │            └──────────────────┘           │                       │
│         └───────────────────┴───────────────────────┘                       │
│                    virbr-sieste (10.99.0.0/24)                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Zero-Touch Provisioning Flow

```
┌────────────────────────────────────────────────────────────────────────────┐
│  1. PXE BOOT                                                                │
├────────────────────────────────────────────────────────────────────────────┤
│  Node powers on → DHCP (dnsmasq) → TFTP (kernel + initramfs)               │
└────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  2. REGISTRATION                                                            │
├────────────────────────────────────────────────────────────────────────────┤
│  initramfs runs → collects hardware info → POST /register                  │
│  → Discovery server assigns node ID                                         │
└────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  3. IMAGE DOWNLOAD (if sieste.install=yes)                                  │
├────────────────────────────────────────────────────────────────────────────┤
│  GET /images/<name> → download pre-built OS image (gzipped)                │
│  → write to disk with dd                                                    │
└────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  4. CLOUD-INIT INJECTION                                                    │
├────────────────────────────────────────────────────────────────────────────┤
│  GET /nodes/:id/cloud-init → mount root partition                          │
│  → write to /var/lib/cloud/seed/nocloud/ (NoCloud datasource)              │
└────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│  5. REBOOT & FIRST BOOT                                                     │
├────────────────────────────────────────────────────────────────────────────┤
│  Reboot to installed OS → cloud-init runs:                                 │
│  - Configure hostname, network                                              │
│  - Install k3s (control-plane or worker)                                    │
│  - Join cluster                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

## Components

1. **dnsmasq** - DHCP + TFTP server for PXE boot
2. **Discovery Server** - OCaml HTTP server for:
   - Node registration and discovery
   - Cloud-init configuration generation
   - OS image serving
   - k3s cluster configuration
3. **QEMU VMs** - Test nodes that boot via PXE
4. **Pre-built images** - OS images with cloud-init (Ubuntu/Alpine)

## Quick Start

### Discovery Mode (testing only)

```bash
# 1. Setup network bridge (requires root)
sudo ./setup-network.sh

# 2. Start dnsmasq (requires root)
sudo ./start-dnsmasq.sh

# 3. Start discovery server (user mode)
./start-discovery-server.sh

# 4. Spawn test VMs (discovery only, no installation)
./spawn-vm.sh node1
./spawn-vm.sh node2

# 5. Query discovered nodes
curl http://localhost:8877/nodes
```

### Full Provisioning Mode

```bash
# 1. Setup (same as above)
sudo ./setup-network.sh
sudo ./start-dnsmasq.sh
./start-discovery-server.sh

# 2. Create or download OS image
# Option A: Build test image (requires root)
sudo ./build-test-image.sh

# Option B: Download Ubuntu cloud image
wget -O images/ubuntu-22.04-minimal.img.gz \
  https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img

# 3. Configure discovery server
curl -X POST http://localhost:8877/config \
  -H 'Content-Type: application/json' \
  -d '{"image_url": "http://10.99.0.1:8877/images/ubuntu-22.04-minimal.img.gz"}'

# 4. Spawn VM with installation enabled
qemu-system-x86_64 \
  -m 2048 -smp 2 \
  -drive file=/tmp/node1-disk.qcow2,format=qcow2 \
  -boot n \
  -append "sieste.install=yes sieste.role=control-plane sieste.hostname=master1" \
  ...

# 5. After reboot, node will have k3s installed
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/register` | POST | Register a new node |
| `/nodes` | GET | List all discovered nodes |
| `/nodes/:id` | GET | Get node by ID |
| `/nodes/:id` | DELETE | Remove a node |
| `/nodes/:id/cloud-init` | GET | Get cloud-init user-data for node |
| `/config` | GET | Get cluster configuration |
| `/config` | POST | Update cluster configuration |
| `/images` | GET | List available OS images |
| `/images/:name` | GET | Download OS image file |
| `/health` | GET | Health check |

## Kernel Command Line Options

The initramfs accepts these kernel parameters:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `sieste.discovery=URL` | Discovery server URL | `http://10.0.2.2:8877` |
| `sieste.hostname=NAME` | Node hostname | `sieste-node-$$` |
| `sieste.role=ROLE` | Node role: `control-plane` or `worker` | `worker` |
| `sieste.install=yes` | Enable OS installation | `no` |
| `sieste.disk=DEVICE` | Target disk device | auto-detect |
| `sieste.image=URL` | OS image URL (overrides config) | from server |

## Files

- `setup-network.sh` - Create isolated network bridge
- `teardown-network.sh` - Remove network bridge
- `start-dnsmasq.sh` - Start DHCP/TFTP server
- `stop-dnsmasq.sh` - Stop DHCP/TFTP server
- `dnsmasq.conf` - dnsmasq configuration
- `start-discovery-server.sh` - Start OCaml discovery server
- `spawn-vm.sh` - Create a test VM with PXE boot
- `build-test-image.sh` - Build minimal test OS image
- `pxe-build/init` - Initramfs init script (registration + provisioning)
- `tftp/` - PXE boot files (kernel, initramfs)
- `images/` - OS images for provisioning

## Network Configuration

- Bridge: `virbr-sieste`
- Subnet: `10.99.0.0/24`
- Gateway/Discovery: `10.99.0.1`
- DHCP range: `10.99.0.100-10.99.0.200`
- Discovery server: `10.99.0.1:8877`

## Requirements

- QEMU/KVM
- dnsmasq
- bridge-utils (for brctl)
- OCaml with cohttp-lwt-unix (already in sieste dependencies)

## Cloud-Init Configuration

The discovery server generates cloud-init user-data based on node role:

### Control-Plane Node (first)
```yaml
#cloud-config
hostname: master1
runcmd:
  - curl -sfL https://get.k3s.io | sh -s - server --cluster-init
  # Registers k3s token back to discovery server
```

### Additional Control-Plane
```yaml
#cloud-config
hostname: master2
runcmd:
  - curl -sfL https://get.k3s.io | K3S_URL=... K3S_TOKEN=... sh -s - server
```

### Worker Node
```yaml
#cloud-config
hostname: worker1
runcmd:
  - curl -sfL https://get.k3s.io | K3S_URL=... K3S_TOKEN=... sh -s - agent
```

## Security Notes

- **ANSSI Recommendation**: Using pre-built, signed OS images is more secure than network installation
- Images should be built in a secure CI/CD pipeline
- Production deployments should verify image signatures
- The NoCloud datasource is injected locally, no network metadata service needed
