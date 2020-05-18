#!/bin/sh
ufw default deny incoming
ufw limit in 22/tcp comment "rate-limit SSH"
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
