#!/bin/bash

# Create and navigate to the nextcloud directory
mkdir -p nextcloud
cd nextcloud || { echo "Failed to navigate to nextcloud directory"; exit 1; }

# Define the content for the .env file
cat <<EOF > .env
MYSQL_ROOT_PASSWORD=your_password
MYSQL_USER=nextcloud
MYSQL_PASSWORD=nextcloud_password
MYSQL_DATABASE=nextcloud
MYSQL_HOST=db
REDIS_HOST=redis
OVERWRITEPROTOCOL=https
TRUSTED_PROXIES=caddy
APACHE_DISABLE_REWRITE_IP=1
OVERWRITEHOST=nextcloud.tmplinux.com
EOF

# Print a message indicating the .env file has been created
echo ".env file created with the specified content."

# Create Docker network
docker network create nextcloud_network

# Create nginx.conf
cat <<EOF > nginx.conf
worker_processes auto;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;
    server_tokens   off;
    keepalive_timeout  65;
    #gzip  on;

    upstream php-handler {
        server nextcloud:9000;
    }

    server {
        listen 80;
        client_max_body_size 512M;
        fastcgi_buffers 64 4K;

        gzip on;
        gzip_vary on;
        gzip_comp_level 4;
        gzip_min_length 256;
        gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
        gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;

        add_header Referrer-Policy                      "no-referrer"       always;
        add_header X-Content-Type-Options               "nosniff"           always;
        add_header X-Download-Options                   "noopen"            always;
        add_header X-Frame-Options                      "SAMEORIGIN"        always;
        add_header X-Permitted-Cross-Domain-Policies    "none"              always;
        add_header X-Robots-Tag                         "noindex, nofollow" always;
        add_header X-XSS-Protection                     "1; mode=block"     always;

        fastcgi_hide_header X-Powered-By;
        root /var/www/html;
        index index.php index.html /index.php$request_uri;

        location = / {
            if ( \$http_user_agent ~ ^DavClnt ) {
                return 302 /remote.php/webdav/\$is_args\$args;
            }
        }

        location = /robots.txt {
            allow all;
            log_not_found off;
            access_log off;
        }

        location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:\$|/)  { return 404; }
        location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)                { return 404; }

        location ~ \.php(?:\$|/) {
            rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+|.+\/richdocumentscode\/proxy) /index.php\$request_uri;

            fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
            set \$path_info \$fastcgi_path_info;
            try_files \$fastcgi_script_name =404;

            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param PATH_INFO \$path_info;
            #fastcgi_param HTTPS on;

            fastcgi_param modHeadersAvailable true;
            fastcgi_param front_controller_active true;
            fastcgi_pass php-handler;

            fastcgi_intercept_errors on;
            fastcgi_request_buffering off;
        }

        location ~ \.(?:css|js|svg|gif)\$ {
            try_files \$uri /index.php\$request_uri;
            expires 6M;
            access_log off;
        }

        location ~ \.woff2?\$ {
            try_files \$uri /index.php\$request_uri;
            expires 7d;
            access_log off;
        }

        location /remote {
            return 301 /remote.php\$request_uri;
        }

        location / {
            try_files \$uri \$uri/ /index.php\$request_uri;
        }
    }
}
EOF

# Create php-fpm-www.conf
cat <<EOF > php-fpm-www.conf
user = www-data
group = www-data
pm = dynamic
pm.max_children = 281
pm.start_servers = 140
pm.min_spare_servers = 93
pm.max_spare_servers = 187
EOF

# Create compose.yaml file
cat <<EOF > compose.yaml
services:

  caddy:
    image: lucaslorentz/caddy-docker-proxy:ci-alpine
    container_name: reverse-proxy
    ports:
      - 80:80
      - 443:443
    environment:
      - CADDY_INGRESS_NETWORKS=nextcloud_network
    networks:
      - nextcloud_network
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - caddy_data:/data
    restart: unless-stopped

  web:
    image: nginx:alpine
    container_name: nextcloud-web
    networks:
      - nextcloud_network
    links:
      - nextcloud
    labels:
      caddy: nextcloud.tmplinux.com
      caddy.reverse_proxy: "{{upstreams}}"
      caddy.header: /*
      caddy.header.Strict-Transport-Security: '"max-age=15552000;"'
      caddy.rewrite_0: /.well-known/carddav /remote.php/dav
      caddy.rewrite_1: /.well-known/caldav /remote.php/dav
      caddy.rewrite_2: /.well-known/webfinger /index.php/.well-known/webfinger
      caddy.rewrite_3: /.well-known/nodeinfo /index.php/.well-known/nodeinfo
    volumes:
      - nextcloud_data:/var/www/html:z,ro
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    restart: unless-stopped

  db:
    image: mariadb:10.11
    container_name: mariadb-database
    command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW
    networks:
      - nextcloud_network
    volumes:
      - db_data:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD
      - MYSQL_USER
      - MYSQL_PASSWORD
      - MYSQL_DATABASE
    restart: unless-stopped

  redis:
    image: redis:alpine
    container_name: redis-dbcache
    networks:
      - nextcloud_network
    restart: unless-stopped

  nextcloud:
    image: nextcloud:stable-fpm
    container_name: nextcloud-app
    networks:
      - nextcloud_network
    volumes:
      - nextcloud_data:/var/www/html:z
      - ./php-fpm-www.conf:/usr/local/etc/php-fpm.d/www.conf:ro
    environment:
      - MYSQL_USER
      - MYSQL_PASSWORD
      - MYSQL_DATABASE
      - MYSQL_HOST
      - REDIS_HOST
      - OVERWRITEPROTOCOL
      - OVERWRITEHOST
      - TRUSTED_PROXIES
      - APACHE_DISABLE_REWRITE_IP
    restart: unless-stopped
    depends_on:
      - caddy
      - db
      - redis

  cron:
    image: nextcloud:stable-fpm
    container_name: nextcloud-cron
    networks:
      - nextcloud_network
    volumes:
      - nextcloud_data:/var/www/html:z
    entrypoint: /cron.sh
    restart: unless-stopped
    depends_on:
      - db
      - redis

networks:
  nextcloud_network:
    external: true

volumes:
  caddy_data: {}
  db_data: {}
  nextcloud_data: {}
EOF

# Pull the images specified in the compose.yaml file
docker compose pull

# Validate the configuration
docker compose config

# Uncomment the following line to build and start the containers
# docker compose up --build -d
