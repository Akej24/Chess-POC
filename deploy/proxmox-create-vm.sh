#!/usr/bin/env bash
# Create the Stockfish FEN viewer VM on a Proxmox VE host, end to end.
# Run as root ON THE PROXMOX HOST (its web UI "Shell" works, or SSH):
#
#   bash proxmox-create-vm.sh --repo https://github.com/YOU/REPO.git \
#        --ssh-key "ssh-ed25519 AAAA... you@mac"
#
# What it does (safe to re-run; the template is built only once):
#   1. downloads and verifies the Ubuntu 24.04 cloud image
#   2. builds a reusable VM template from it (first run only)
#   3. enables Snippets on the 'local' storage and writes a cloud-init file
#   4. clones the template into a new VM, boots it and waits until the viewer answers
#
# The repository must be public (for a private one see deploy/README.md).
#
# Options:
#   --repo URL        GitHub repository to deploy                  (required)
#   --ssh-key KEY     public key text, or path to a .pub file here (required)
#   --branch NAME     branch to deploy                (default: main)
#   --name NAME       VM name                         (default: stockfish-web)
#   --vmid N          VM id                           (default: next free id)
#   --ip ADDR/CIDR    static IP, e.g. 192.168.1.50/24 (default: dhcp)
#   --gw ADDR         gateway, required with a static --ip
#   --cores N         CPU cores                       (default: 2)
#   --memory MB       RAM in MB                       (default: 2048)
#   --disk SIZE       disk size                       (default: 16G)
#   --storage NAME    storage for the VM disk         (default: first active one)
#   --bridge NAME     network bridge                  (default: vmbr0)
#   --template-id N   id used for the template        (default: 9000)
set -euo pipefail

REPO=""
SSH_KEY_ARG=""
BRANCH="main"
NAME="stockfish-web"
VMID=""
IP="dhcp"
GW=""
CORES=2
MEMORY=2048
DISK="16G"
STORAGE=""
BRIDGE="vmbr0"
TEMPLATE_ID=9000
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_NAME="noble-server-cloudimg-amd64.img"
IMG_DIR="${IMG_DIR:-/var/tmp}"

die() { echo "Error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)        REPO="${2:?--repo needs a value}"; shift 2 ;;
    --ssh-key)     SSH_KEY_ARG="${2:?--ssh-key needs a value}"; shift 2 ;;
    --branch)      BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --name)        NAME="${2:?--name needs a value}"; shift 2 ;;
    --vmid)        VMID="${2:?--vmid needs a value}"; shift 2 ;;
    --ip)          IP="${2:?--ip needs a value}"; shift 2 ;;
    --gw)          GW="${2:?--gw needs a value}"; shift 2 ;;
    --cores)       CORES="${2:?--cores needs a value}"; shift 2 ;;
    --memory)      MEMORY="${2:?--memory needs a value}"; shift 2 ;;
    --disk)        DISK="${2:?--disk needs a value}"; shift 2 ;;
    --storage)     STORAGE="${2:?--storage needs a value}"; shift 2 ;;
    --bridge)      BRIDGE="${2:?--bridge needs a value}"; shift 2 ;;
    --template-id) TEMPLATE_ID="${2:?--template-id needs a value}"; shift 2 ;;
    -h|--help)     sed -n '2,31p' "$0"; exit 0 ;;
    *)             die "Unknown option: $1 (see --help)" ;;
  esac
done

# ---- checks -----------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run as root on the Proxmox host."
command -v qm >/dev/null 2>&1 || die "'qm' not found. Run this on the Proxmox VE host, not on your own computer."
[ -n "$REPO" ] || die "--repo is required (your GitHub repository URL)."
[ -n "$SSH_KEY_ARG" ] || die "--ssh-key is required (your public key, e.g. \"\$(cat ~/.ssh/id_ed25519.pub)\")."
if [ "$IP" != "dhcp" ] && [ -z "$GW" ]; then
  die "A static --ip needs --gw as well."
fi

if [ -f "$SSH_KEY_ARG" ]; then
  SSH_KEY="$(head -n1 "$SSH_KEY_ARG")"
else
  SSH_KEY="$SSH_KEY_ARG"
fi
case "$SSH_KEY" in
  ssh-*|ecdsa-*|sk-*) ;;
  *) die "--ssh-key must be a public key (starts with ssh-ed25519, ssh-rsa, ...)." ;;
esac

if [ -z "$VMID" ]; then
  VMID="$(pvesh get /cluster/nextid | tr -d '"')"
fi
if qm status "$VMID" >/dev/null 2>&1; then
  die "VM $VMID already exists. Pick another with --vmid, or remove it: qm stop $VMID; qm destroy $VMID"
fi

if [ -z "$STORAGE" ]; then
  STORAGE="$(pvesm status --content images | awk 'NR>1 && $3=="active" && !seen {print $1; seen=1}')"
fi
[ -n "$STORAGE" ] || die "No active storage that can hold VM disks was found. Pass one with --storage."

# ---- template ---------------------------------------------------------------
verify_image() {
  local want got
  want="$(wget -qO- "${IMG_URL%/*}/SHA256SUMS" | awk -v f="*$IMG_NAME" '$2==f {print $1}')"
  [ -n "$want" ] || die "Could not fetch the published checksum for $IMG_NAME."
  got="$(sha256sum "$1" | awk '{print $1}')"
  if [ "$want" != "$got" ]; then
    rm -f "$1"
    die "Checksum mismatch for $IMG_NAME. The download was removed; run the script again."
  fi
}

create_template() {
  local img="$IMG_DIR/$IMG_NAME" disk

  log "Downloading the Ubuntu 24.04 cloud image"
  wget -q --show-progress -O "$img" "$IMG_URL"
  log "Verifying its checksum"
  verify_image "$img"

  log "Building template $TEMPLATE_ID on storage '$STORAGE'"
  qm create "$TEMPLATE_ID" --name ubuntu-2404-template --memory 2048 --cores 2 --cpu host \
    --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-pci
  qm disk import "$TEMPLATE_ID" "$img" "$STORAGE" >/dev/null \
    || qm importdisk "$TEMPLATE_ID" "$img" "$STORAGE" >/dev/null
  disk="$(qm config "$TEMPLATE_ID" | awk -F': ' '/^unused0:/ {print $2}')"
  [ -n "$disk" ] || die "Disk import failed. Remove the half-built template with: qm destroy $TEMPLATE_ID"
  qm set "$TEMPLATE_ID" --scsi0 "$disk" --ide2 "$STORAGE:cloudinit" \
    --boot order=scsi0 --serial0 socket --vga serial0 --agent enabled=1
  qm template "$TEMPLATE_ID"
  rm -f "$img"
}

if qm status "$TEMPLATE_ID" >/dev/null 2>&1; then
  template_cfg="$(qm config "$TEMPLATE_ID")"
  case "$template_cfg" in
    *"template: 1"*) log "Reusing existing template $TEMPLATE_ID" ;;
    *) die "VM $TEMPLATE_ID exists but is not a template. Use --template-id, or remove it: qm destroy $TEMPLATE_ID" ;;
  esac
else
  create_template
fi

# ---- cloud-init -------------------------------------------------------------
content="$(pvesh get /storage/local --output-format json \
  | python3 -c 'import json, sys; print(json.load(sys.stdin).get("content", ""))')"
case ",$content," in
  *,snippets,*) ;;
  *)
    log "Enabling Snippets on storage 'local'"
    pvesm set local --content "${content:+$content,}snippets"
    ;;
esac

SNIPPET_FILE="$NAME-user.yaml"
SNIPPET_PATH="$(pvesm path "local:snippets/$SNIPPET_FILE")"
mkdir -p "$(dirname "$SNIPPET_PATH")"

log "Writing cloud-init file $SNIPPET_PATH"
cat > "$SNIPPET_PATH" <<EOF
#cloud-config
hostname: $NAME
manage_etc_hosts: true

users:
  - name: admin
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - "$SSH_KEY"

package_update: true
packages:
  - qemu-guest-agent
  - git

runcmd:
  - systemctl enable --now qemu-guest-agent
  - git clone --branch $BRANCH $REPO /root/src
  - REPO_URL=$REPO BRANCH=$BRANCH bash /root/src/deploy/install.sh
  - rm -rf /root/src
EOF

# ---- the VM -----------------------------------------------------------------
if [ "$IP" = "dhcp" ]; then
  IPCFG="ip=dhcp"
else
  IPCFG="ip=$IP,gw=$GW"
fi

log "Creating VM $VMID ($NAME)"
qm clone "$TEMPLATE_ID" "$VMID" --name "$NAME" --full
qm set "$VMID" --cores "$CORES" --memory "$MEMORY" --onboot 1 \
  --net0 "virtio,bridge=$BRIDGE" \
  --cicustom "user=local:snippets/$SNIPPET_FILE" --ipconfig0 "$IPCFG"
qm resize "$VMID" scsi0 "$DISK"
qm start "$VMID"

# ---- wait until it works ----------------------------------------------------
get_ip() {
  qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for nic in data:
    if nic.get("name") == "lo":
        continue
    for addr in nic.get("ip-addresses", []):
        if addr.get("ip-address-type") == "ipv4":
            print(addr["ip-address"])
            sys.exit(0)
sys.exit(1)
'
}

vm_ip=""
if [ "$IP" != "dhcp" ]; then
  vm_ip="${IP%%/*}"
else
  log "Waiting for the VM to get an IP address (first boot installs everything, a few minutes)"
  for _ in $(seq 1 90); do
    vm_ip="$(get_ip || true)"
    [ -n "$vm_ip" ] && break
    sleep 5
  done
fi

if [ -z "$vm_ip" ]; then
  echo
  echo "VM $VMID is running, but it has not reported an IP address yet."
  echo "Check VM $VMID, Summary in the Proxmox web UI (or your router's device list) in a few minutes."
  exit 0
fi

log "VM is at $vm_ip, waiting for the viewer to start"
ready=0
for _ in $(seq 1 120); do
  if curl -fsS -m 3 "http://$vm_ip:8000/api/state" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 5
done

echo
if [ "$ready" -eq 1 ]; then
  echo "Done. The viewer is up."
else
  echo "The VM is up, but the viewer is not answering yet. Look at the install progress with:"
  echo "  ssh admin@$vm_ip 'cloud-init status --long; sudo journalctl -u stockfish-web -n 50'"
  echo
fi
echo "Viewer : http://$vm_ip:8000"
echo "SSH    : ssh admin@$vm_ip"
echo "Test   : curl -G http://$vm_ip:8000/api/fen --data-urlencode \"fen=start\""
echo "Updates: pulled from GitHub (branch $BRANCH) every 5 minutes"
