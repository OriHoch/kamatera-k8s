#!/usr/bin/env bash

echo 'server {
  listen 80;
  listen    [::]:80;
  include snippets/rancher_server_name.conf;
  include snippets/letsencrypt.conf;
  return 301 https://$host$request_uri;
}
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  include snippets/rancher_server_name.conf;
  include snippets/cloud_management_certs.conf;
  include snippets/ssl.conf;
  include snippets/letsencrypt.conf;
  location / {
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_pass http://localhost:8000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
    # This allows the ability for the execute shell window to remain open for up to 15 minutes. Without this parameter, the default is 1 minute and will automatically close.
    proxy_read_timeout 900s;
  }
}
' | tee /etc/nginx/sites-enabled/rancher &&\
echo "  server_name ${LETSENCRYPT_DOMAIN};" | tee /etc/nginx/snippets/rancher_server_name.conf &&\
systemctl restart nginx
[ "$?" != "0" ] && exit 1

echo Great Success!
exit 0
