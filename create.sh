#!/bin/sh
set -o errexit # abort on nonzero exitstatus
set -o nounset # abort on unbound variable

SECONDS=0

ENVFILE=".env"
INSTALL_DIR="./install"

echo "1. Check for environment"
if [ ! -f "${ENVFILE}" ]; then
    echo "Abort. You must provide a ${ENVFILE}."
    exit
fi

echo "2. Get environment variables from .env"
set -o allexport
source ./.env
set +o allexport

SSH_PORT=${SSH_PORT} || 22
echo ${SSH_PORT}

echo "3. Create Floating IP if not exists"
FLOATING_IP4=$(hcloud floating-ip list -l name=${CLOUD_SERVER_NAME} -o noheader -o columns=ip)
if [ -z "${FLOATING_IP4}" ]
then
	hcloud floating-ip create \
		--description ${CLOUD_SERVER_NAME} \
		--home-location ${CLOUD_SERVER_LOCATION} \
		--type ipv4 \
		--label name=${CLOUD_SERVER_NAME}
	FLOATING_IP4=$(hcloud floating-ip list -l name=${CLOUD_SERVER_NAME} -o noheader -o columns=ip)
else
	echo "Floating IP exists. IP: ${FLOATING_IP4}"
fi
FLOATING_ID=$(hcloud floating-ip list -l name=${CLOUD_SERVER_NAME} -o noheader -o columns=id)
hcloud floating-ip set-rdns --hostname ${DOMAIN} ${FLOATING_ID}

echo "4. Create server on Hetzner Cloud"
hcloud server create \
	--name ${CLOUD_SERVER_NAME} \
	--image ${CLOUD_SERVER_IMAGE} \
	--type ${CLOUD_SERVER_TYPE} \
	--location ${CLOUD_SERVER_LOCATION} \
	--ssh-key  ${CLOUD_SSH_KEY}
hcloud floating-ip assign ${FLOATING_ID} ${CLOUD_SERVER_NAME}
SERVER_IP4=$(hcloud server ip ${CLOUD_SERVER_NAME})

echo "5. Make sure to make the following entries in your DNS zone file:"
echo "Type	Name 			Value		TTL"
echo "A 	@.${DOMAIN}	${FLOATING_IP4}	3600"
echo "A 	www.${DOMAIN}	${FLOATING_IP4}	3600"
echo "A 	cms.${DOMAIN}	${FLOATING_IP4}	3600"
echo "Press [ENTER] to confirm"
read

echo '6. Wait for ping contact ...'${SERVER_IP4}
while ! ping -c1 ${SERVER_IP4} &>/dev/null; do sleep 1; done

echo '7. Wait for port contact ...'${SERVER_IP4}' on port 22'
while ! nmap -Pn -p 22 ${SERVER_IP4} |grep "open" &>/dev/null; do sleep 2; done

echo '8. Install bind-utils'
KNOWNHOSTS=~/.ssh/known_hosts
if [ -e "${KNOWNHOSTS}" ]
then
	sed -i /${SERVER_IP4}/d ${KNOWNHOSTS}
fi
ssh root@${SERVER_IP4} dnf -y install bind-utils

echo "9. Test reverse DNS"
IP_ROOT=$(ssh root@${SERVER_IP4} dig +short ${DOMAIN})
if [ ! "${IP_ROOT}" == "${FLOATING_IP4}" ]
then
	echo "Abort. Check your DNS zone file (you may have to wait up to 48 hours)."
	hcloud server delete ${CLOUD_SERVER_NAME}
	exit
fi	
IP_WWW=$(ssh root@${SERVER_IP4} dig +short www.${DOMAIN})
if [ ! "${IP_WWW}" == "${FLOATING_IP4}" ]
then
	echo "Abort. Check your DNS zone file (you may have to wait up to 48 hours)."
	hcloud server delete ${CLOUD_SERVER_NAME}
	exit
fi
IP_CMS=$(ssh root@${SERVER_IP4} dig +short cms.${DOMAIN})
if [ ! "${IP_CMS}" == "${FLOATING_IP4}" ]
then
	echo "Abort. Check your DNS zone file (you may have to wait up to 48 hours)."
	hcloud server delete ${CLOUD_SERVER_NAME}
	exit
fi

echo '10. Substitute secrets'
mkdir -p remote
eval "echo \"$(cat ${INSTALL_DIR}/docker-compose.yml)\"" > ./remote/docker-compose.yml
eval "echo \"$(cat ${INSTALL_DIR}/cms-ghost.conf)\"" > ./remote/cms-ghost.conf
eval "echo \"$(cat ${INSTALL_DIR}/ifcfg-eth0:1)\"" > ./remote/ifcfg-eth0:1


echo '11.0 Check for private firewall config'
FW_FILE="./private/firewall2.sh"
if [ ! -f "${FW_FILE}" ]
then
	FW_FILE="${INSTALL_DIR}/firewall.sh"
else 
	scp -oStrictHostKeyChecking=no ./private/fw-install.sh root@${SERVER_IP4}:
	scp -oStrictHostKeyChecking=no ./private/fwstart.sh root@${SERVER_IP4}:
fi

echo '11. Copy files and directories'
scp -oStrictHostKeyChecking=no "${INSTALL_DIR}/pre-install.sh" root@${SERVER_IP4}:
scp -oStrictHostKeyChecking=no "${INSTALL_DIR}/install.sh" root@${SERVER_IP4}:
scp -oStrictHostKeyChecking=no "${FW_FILE}" root@${SERVER_IP4}:
scp -oStrictHostKeyChecking=no ./remote/docker-compose.yml root@${SERVER_IP4}:
scp -oStrictHostKeyChecking=no ./remote/cms-ghost.conf root@${SERVER_IP4}:
scp -oStrictHostKeyChecking=no ./remote/ifcfg-eth0:1 root@${SERVER_IP4}:/etc/sysconfig/network-scripts/ifcfg-eth0:1
scp -oStrictHostKeyChecking=no "${INSTALL_DIR}/backup-weekly.service" root@${SERVER_IP4}:/usr/lib/systemd/system/backup-weekly.service
scp -oStrictHostKeyChecking=no "${INSTALL_DIR}/backup-weekly.timer" root@${SERVER_IP4}:/usr/lib/systemd/system/backup-weekly.timer
scp -oStrictHostKeyChecking=no "${INSTALL_DIR}/system-update.service" root@${SERVER_IP4}:/usr/lib/systemd/system/system-update.service
scp -oStrictHostKeyChecking=no "${INSTALL_DIR}/system-update.timer" root@${SERVER_IP4}:/usr/lib/systemd/system/system-update.timer
scp -oStrictHostKeyChecking=no "${INSTALL_DIR}/system-reboot.service" root@${SERVER_IP4}:/usr/lib/systemd/system/system-reboot.service
scp -oStrictHostKeyChecking=no "${INSTALL_DIR}/system-reboot.timer" root@${SERVER_IP4}:/usr/lib/systemd/system/system-reboot.timer

echo '12. Copy available certificates'
if [ -d letsencrypt ]
then
	echo "letsencrypt directory found..."
    scp -r letsencrypt root@${SERVER_IP4}:/etc/
fi

echo '13. Pre-Install, Reboot'
ssh root@${SERVER_IP4} sh pre-install.sh ${SSH_PORT} ${FLOATING_IP4} ${SERVER_IP4}
ssh -p ${SSH_PORT} root@${SERVER_IP4} reboot

echo '14. Wait for ping contact ...'${SERVER_IP4}
while ! ping -c1 ${SERVER_IP4} &>/dev/null; do sleep 1; done

echo '15. Wait for port contact ...'${SERVER_IP4}' on port '${SSH_PORT}
while ! nmap -Pn -p ${SSH_PORT} ${SERVER_IP4} |grep "open" &>/dev/null; do sleep 2; done

echo '16. Install remote'
ssh -p ${SSH_PORT} root@${SERVER_IP4} sh install.sh ${DOMAIN} ${EMAIL}

echo '17. Remove temporary files'
rm -rf remote

echo '18. Save certificates locally'
if [ -d letsencrypt ]
then
	echo "move existing directory..."
    mv letsencrypt letsencrypt_$(date +%Y%m%d)
fi
scp -r -P ${SSH_PORT} root@${SERVER_IP4}:/etc/letsencrypt .

duration=$SECONDS
echo "$(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

echo '29. Register Ghost'
echo "Please go to https://cms.${DOMAIN}/ghost and complete the setup!"
echo "Log into your system with ssh -p ${SSH_PORT} root@${DOMAIN}"
