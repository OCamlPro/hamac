# SIESTE Infrastructure Discovery Prototype

Local prototype for testing PXE-based infrastructure discovery using QEMU/KVM.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Host Machine                              │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │   dnsmasq    │    │  Discovery   │    │    QEMU      │  │
│  │  DHCP/TFTP   │◄──►│    Server    │◄──►│     VMs      │  │
│  │  (port 67)   │    │  (port 8877) │    │  (PXE boot)  │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│         │                   │                    │          │
│         └───────────────────┴────────────────────┘          │
│                    virbr-sieste (10.99.0.0/24)              │
└─────────────────────────────────────────────────────────────┘
```

## Components

1. **dnsmasq** - DHCP + TFTP server for PXE boot
2. **Discovery Server** - OCaml HTTP server for node registration
3. **QEMU VMs** - Test nodes that boot via PXE and register

## Quick Start

```bash
# 1. Setup network bridge (requires root)
sudo ./setup-network.sh

# 2. Start dnsmasq (requires root)
sudo ./start-dnsmasq.sh

# 3. Start discovery server (user mode)
./start-discovery-server.sh

# 4. Spawn test VMs
./spawn-vm.sh node1
./spawn-vm.sh node2

# 5. Query discovered nodes
curl http://localhost:8877/nodes
```

## Files

- `setup-network.sh` - Create isolated network bridge
- `start-dnsmasq.sh` - Start DHCP/TFTP server
- `dnsmasq.conf` - dnsmasq configuration
- `start-discovery-server.sh` - Start OCaml discovery server
- `spawn-vm.sh` - Create a test VM with PXE boot
- `pxe/` - PXE boot files (iPXE, registration script)

## Network Configuration

- Bridge: `virbr-sieste`
- Subnet: `10.99.0.0/24`
- Gateway: `10.99.0.1`
- DHCP range: `10.99.0.100-10.99.0.200`
- Discovery server: `10.99.0.1:8877`

## Requirements

- QEMU/KVM
- dnsmasq
- bridge-utils (for brctl)
- OCaml with cohttp-lwt-unix (already in sieste dependencies)
