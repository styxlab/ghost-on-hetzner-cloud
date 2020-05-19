#!/bin/sh
set -o errexit # abort on nonzero exitstatus
set -o nounset # abort on unbound variable

SSH_PORT=$1
FLOATING_IP4=$2
SERVER_IP4=$3

echo "11.1 switch ssh port"
if [ -n "${SSH_PORT}" ] && [ "${SSH_PORT}" != 22 ]
then
	sed -i "s|#Port 22|Port ${SSH_PORT}|g" /etc/ssh/sshd_config
	systemctl restart sshd
fi

echo "11.2 Restart network (needed for Floating IP)"
systemctl restart network

echo "11.3 Install firewall"
TESTFILE="./fwstart.sh"
if [ -e "${TESTFILE}" ]
then
	sh ./fw-install.sh ${FLOATING_IP4} ${SERVER_IP4}
else
	sed -i "s|__SSH_PORT__|${SSH_PORT}|g" ./firewall.sh
	dnf -y install ufw
	sh ./firewall.sh
	systemctl enable --now ufw.service
fi

echo "11.4 Update system"
dnf -y update
systemctl daemon-reload

echo "11.5 Kernel tweak for docker"
grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=0"
