# Ingress: only the Home Assistant Supervisor may connect. Everything else on
# the add-on network is refused, so the terminal is not reachable from other
# add-ons. The page at / is a bar with two links over one terminal: Claude
# Code's session, and a shell.
worker_processes 1;
pid /run/nginx.pid;
error_log stderr warn;
events { worker_connections 64; }
http {
  access_log off;
  map $http_upgrade $connection_upgrade { default upgrade; '' close; }
  server {
    listen 7681;
    __ALLOW__
    location = / {
      root /usr/share/ha-claude;
      default_type text/html;
      try_files /index.html =404;
    }
    location / { return 404; }
    location /claude/ {
      proxy_pass http://127.0.0.1:7682/;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_read_timeout 86400s;
    }
    location /shell/ {
      proxy_pass http://127.0.0.1:7683/;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_read_timeout 86400s;
    }
  }
}
