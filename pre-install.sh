#!/bin/sh
set -o errexit # abort on nonzero exitstatus
set -o nounset # abort on unbound variable

echo "11.1 Restart network (needed for Floating IP)"
systemctl restart network

echo "11.2 Install firewall"
dnf -y install ufw
sh ./firewall.sh
systemctl enable --now ufw.service

echo "11.3 Update system"
dnf -y update

echo "11.4 Kernel tweak for docker"
grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=0"