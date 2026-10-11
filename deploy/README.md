# Deploying to Proxmox from GitHub

Everything runs on your own hardware. The VM only makes outbound connections to
GitHub, so you don't need to open any inbound ports for deployment.

How it works:

1. You push code to GitHub.
2. A systemd timer on the VM checks GitHub every 5 minutes (`update.sh`).
3. If there are new commits, it pulls them, updates dependencies and restarts the
   service. If nothing changed, it does nothing.

## 1. Put the project on GitHub

```bash
cd chess-stockfish
git init -b main
git add .
git commit -m "Initial commit"
git remote add origin git@github.com:YOUR_USER/YOUR_REPO.git
git push -u origin main
```

`.gitignore` already excludes `.venv/` and `stockfish/`.

## 2. Quickest: one script on the Proxmox host

`proxmox-create-vm.sh` does everything in section 2a for you: it downloads and
verifies the Ubuntu 24.04 cloud image, builds the template (first run only), enables
snippets, writes the cloud-init file, creates and starts the VM, and waits until the
viewer answers. Run it in the Proxmox web UI's **Shell** (node, then Shell) or over SSH:

```bash
curl -fsSL -o create-vm.sh https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/deploy/proxmox-create-vm.sh
bash create-vm.sh --repo https://github.com/YOUR_USER/YOUR_REPO.git \
                  --ssh-key "ssh-ed25519 AAAA... you@mac"
```

Your public key is printed by `cat ~/.ssh/id_ed25519.pub` on your own computer. Useful
options: `--ip 192.168.1.50/24 --gw 192.168.1.1` for a fixed address (default is
DHCP), `--name`, `--vmid`, `--cores`, `--memory`, `--disk`, `--storage`, `--bridge`.
Run `bash create-vm.sh --help` for the full list. Running it again creates another VM
and reuses the template. To remove a VM: `qm stop 120; qm destroy 120`.

## 2a. Step by step (what the script does)

Run these on the **Proxmox host** (shell). Adjust the storage name (`local-lvm`)
and bridge (`vmbr0`) to your setup.

**One-time: create an Ubuntu 24.04 cloud-image template**

```bash
cd /tmp
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

qm create 9000 --name ubuntu-2404-template --memory 2048 --cores 2 --cpu host \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci
qm disk import 9000 noble-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsi0 local-lvm:vm-9000-disk-0 --ide2 local-lvm:cloudinit \
  --boot order=scsi0 --serial0 socket --vga serial0 --agent enabled=1
qm resize 9000 scsi0 16G
qm template 9000
```

`--cpu host` matters: it lets Stockfish use the CPU's modern instructions.

**Per deployment: clone, attach cloud-init, start**

1. Edit `deploy/cloud-init.yaml`: set your GitHub user/repo and your SSH public key.
2. In the Proxmox web UI, enable snippets once: *Datacenter, Storage, local,
   Edit, Content: tick "Snippets"*.
3. Copy the file to the host and create the VM:

```bash
cp cloud-init.yaml /var/lib/vz/snippets/stockfish-user.yaml

qm clone 9000 120 --name stockfish-web --full
qm set 120 --cicustom "user=local:snippets/stockfish-user.yaml" \
  --ipconfig0 ip=192.168.1.50/24,gw=192.168.1.1      # or ip=dhcp
qm start 120
```

After a couple of minutes the viewer is at `http://192.168.1.50:8000`. The same
template and snippet rebuild the VM identically any time.

## 2b. Manual: use an existing VM

On a fresh Debian/Ubuntu VM:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/deploy/install.sh -o install.sh
sudo REPO_URL=https://github.com/YOUR_USER/YOUR_REPO.git bash install.sh
```

## Day to day

```bash
git push                                  # deploys within ~5 minutes
sudo systemctl start stockfish-web-update # deploy right now (on the VM)
journalctl -u stockfish-web -f            # app logs
journalctl -u stockfish-web-update        # what the updater did
systemctl list-timers stockfish-web-update.timer
```

## Private repository

Create a read-only **deploy key** on the VM and add its public half in GitHub
(*Repo, Settings, Deploy keys*):

```bash
sudo -u stockfish ssh-keygen -t ed25519 -N "" -f /home/stockfish/.ssh/id_ed25519
sudo cat /home/stockfish/.ssh/id_ed25519.pub
sudo -u stockfish ssh -o StrictHostKeyChecking=accept-new -T git@github.com
```

Then use the SSH URL (`git@github.com:YOU/REPO.git`) as `REPO_URL`, and clone the
repository by hand instead of using the `curl` line in the cloud-init file.

## Security notes

- The updater runs as root and deploys whatever is on your branch. Anyone who can
  push to it controls the VM, so enable 2FA on GitHub and consider branch protection.
- The viewer has no login. Keep port 8000 on your LAN or behind a VPN (WireGuard,
  Tailscale). Don't port-forward it to the internet without a reverse proxy that
  adds HTTPS and authentication.
