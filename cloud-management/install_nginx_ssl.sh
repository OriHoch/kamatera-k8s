#!/usr/bin/env bash

apt update -y &&\
apt install -y nginx software-properties-common &&\
add-apt-repository ppa:certbot/certbot &&\
apt-get update &&\
apt-get install -y python-certbot-nginx &&\
openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048 &&\
mkdir -p /var/lib/letsencrypt/.well-known &&\
chgrp www-data /var/lib/letsencrypt &&\
chmod g+s /var/lib/letsencrypt &&\
echo 'location ^~ /.well-known/acme-challenge/ {
  allow all;
  root /var/lib/letsencrypt/;
  default_type "text/plain";
  try_files $uri =404;
}' | tee /etc/nginx/snippets/letsencrypt.conf &&\
echo 'ssl_dhparam /etc/ssl/certs/dhparam.pem;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:50m;
ssl_session_tickets off;
ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
ssl_ciphers 'ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA:ECDHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-RSA-AES256-SHA:ECDHE-ECDSA-DES-CBC3-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:DES-CBC3-SHA:!DSS';
ssl_prefer_server_ciphers on;
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 30s;
add_header Strict-Transport-Security "max-age=15768000; includeSubdomains; preload";
add_header X-Frame-Options SAMEORIGIN;
add_header X-Content-Type-Options nosniff;
' | tee /etc/nginx/snippets/ssl.conf &&\
echo 'server {
  listen 80;
  server_name _;
  include snippets/letsencrypt.conf;
  location / {
      return 200 '"'it works!'"';
      add_header Content-Type text/plain;
  }
}' | tee /etc/nginx/sites-enabled/default &&\
systemctl restart nginx
[ "$?" != "0" ] && exit 1

echo Great Success!
exit 0