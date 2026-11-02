#!/usr/bin/env bash
# ============================================================
#  One-time setup for the personal-sites droplet
#  Ubuntu 26.04 LTS, run ONCE as root on a fresh droplet:
#
#    scp setup-droplet.sh root@<public-ip>:
#    ssh root@<public-ip> 'bash setup-droplet.sh'
#
#  Afterwards log in as:  ssh deploy@<public-ip>
#  (root login and password login are switched off at the end)
# ============================================================
set -euo pipefail

DEPLOY_USER=deploy
SWAP_SIZE=2G

echo "==> Updating packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade

# ------------------------------------------------------------
# Automatic security updates — so this box doesn't end up
# like the old 23.10 droplet. Reboots at 4:30 UTC (~11:30pm ET)
# only when an update needs one; containers come back on their own.
# ------------------------------------------------------------
echo "==> Enabling automatic security updates"
apt-get -y install unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

# ------------------------------------------------------------
# Swap — a safety net so a memory spike slows things down
# instead of the kernel killing a container.
# ------------------------------------------------------------
if ! swapon --show | grep -q /swapfile; then
  echo "==> Adding ${SWAP_SIZE} swap"
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
sysctl -p /etc/sysctl.d/99-swappiness.conf

# ------------------------------------------------------------
# Docker (official repo) + log rotation, so container logs
# can't fill the disk.
# ------------------------------------------------------------
echo "==> Installing Docker"
apt-get -y install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl enable docker
systemctl restart docker

# ------------------------------------------------------------
# Firewall: SSH + web only.
# Note: Docker writes its own iptables rules and bypasses ufw for
# any port a container publishes. That's why only Caddy publishes
# ports (80/443) — the apps are reachable only through Caddy.
# ------------------------------------------------------------
echo "==> Configuring firewall"
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp   # HTTP/3
ufw --force enable

# ------------------------------------------------------------
# Deploy user (gets root's SSH key) and the sites folder
# ------------------------------------------------------------
echo "==> Creating ${DEPLOY_USER} user"
if ! id "$DEPLOY_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG docker,sudo "$DEPLOY_USER"
echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-${DEPLOY_USER}
chmod 440 /etc/sudoers.d/90-${DEPLOY_USER}

install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /home/${DEPLOY_USER}/.ssh
install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /root/.ssh/authorized_keys /home/${DEPLOY_USER}/.ssh/authorized_keys

install -d -m 750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/sites

# ------------------------------------------------------------
# SSH hardening — LAST, after the deploy user has a key.
# Named 00-* on purpose: sshd uses the FIRST value it reads, and
# DO's cloud-init writes 50-cloud-init.conf, which would win
# over a file named 99-*.
# ------------------------------------------------------------
echo "==> Hardening SSH"
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sshd -t
systemctl reload ssh

echo
echo "Done. Before closing THIS session, open a new terminal and check:"
echo "    ssh ${DEPLOY_USER}@<public-ip>    docker ps"
echo "If a reboot is needed for the kernel update:  sudo reboot"
