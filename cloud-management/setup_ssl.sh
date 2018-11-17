#!/usr/bin/env bash

LETSENCRYPT_EMAIL="${1}"
LETSENCRYPT_DOMAIN="${2}"

certbot certonly --agree-tos --email ${LETSENCRYPT_EMAIL} --webroot -w /var/lib/letsencrypt/ -d ${LETSENCRYPT_DOMAIN} &&\
echo "
  ssl_certificate /etc/letsencrypt/live/${LETSENCRYPT_DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${LETSENCRYPT_DOMAIN}/privkey.pem;
  ssl_trusted_certificate /etc/letsencrypt/live/${LETSENCRYPT_DOMAIN}/chain.pem;
" | tee /etc/nginx/snippets/cloud_management_certs.conf
[ "$?" != "0" ] && exit 1

echo Great Success!
exit 0
