#!/bin/sh
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw limit in __SSH_PORT__/tcp comment "rate-limit SSH"
ufw allow __SSH_PORT__/tcp
