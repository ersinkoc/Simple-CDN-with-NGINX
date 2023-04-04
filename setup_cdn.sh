#!/bin/bash

# Install required packages
echo "Installing required packages..."
sudo apt-get update
sudo apt-get install -y certbot python3-certbot-nginx openssl nginx nginx-extras nginx-common
sudo mkdir /var/cache/nginx/

# Restart NGINX to apply the changes
sudo systemctl restart nginx

# Read user inputs
read -p "Enter your base domain: (example cdn.myserver.com) " base_domain
if [[ ! $base_domain =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
    echo "Invalid base domain format."
    exit 1
fi

read -p "Enter your CDN subdomain: (example blabla => blabla.cdn.myserver.com) " cdn_subdomain
if [[ ! $cdn_subdomain =~ ^[a-z0-9._-]+$ ]]; then
    echo "Invalid CDN subdomain format."
    exit 1
fi

read -p "Enter custom CDN domain (example cdn.blabla.com) default empty: " custom_cdn_domain
if [ ! -z "$custom_cdn_domain" ] && [[ ! $custom_cdn_domain =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
    echo "Invalid custom CDN domain format."
    exit 1
fi

read -p "Enter the original URL: (example blabla.com/images) " original_url
if [[ ! $original_url =~ ^[a-z0-9.-]+(/.*)?$ ]]; then
    echo "Invalid original URL format."
    exit 1
fi

read -p "Use SSL for CDN (y/n)? " cdn_ssl_input
if [[ ! $cdn_ssl_input =~ ^[yYnN]$ ]]; then
    echo "Invalid SSL input for CDN."
    exit 1
fi

read -p "Use SSL for original domain (y/n)? " original_ssl_input
if [[ ! $original_ssl_input =~ ^[yYnN]$ ]]; then
    echo "Invalid SSL input for original domain."
    exit 1
fi

read -p "Enter cache time (in seconds): (default 86400) " cache_time
if [ -z "$cache_time" ]; then
    cache_time=86400
elif [[ ! $cache_time =~ ^[0-9]+$ ]]; then
    echo "Invalid cache time. Must be a positive integer."
    exit 1
fi

read -p "Enter your email address: " email_address
if [[ ! $email_address =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
    echo "Invalid email address format."
    exit 1
fi


# Set default values
[[ -z $cache_time ]] && cache_time=86400

# If the CDN subdomain is only one word, append the base domain
if [[ $cdn_subdomain != *.* ]]; then
  cdn_subdomain=$cdn_subdomain.$base_domain
fi

first_cdn_subdomain=$cdn_subdomain;

if [[ $original_ssl_input == "y" ]]; then
    original_url="https://$original_url"
else
    original_url="http://$original_url"
fi

# Verify custom domain IP address
if [[ ! -z $custom_cdn_domain ]]; then
  server_ip=$(curl -s https://ipinfo.io/ip)
  custom_domain_ip=$(dig +short $custom_cdn_domain)
  if [[ $server_ip != $custom_domain_ip ]]; then
    echo "The custom domain IP address does not match the server IP address. Exiting..."
    exit 1
  fi
fi


# Function to create NGINX configuration for CDN subdomain
create_cdn_config() {

    # Generate random cache name
    proxy_cache_name=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 10 | head -n 1)

    # Create cache directory for the new CDN subdomain
    sudo mkdir /var/cache/nginx/cache_$cdn_subdomain

    # Add the proxy_cache_path line to the /etc/nginx/cache_config.conf file
    sudo bash -c "echo 'proxy_cache_path /var/cache/nginx/cache_$cdn_subdomain levels=1:2 keys_zone=cache_$proxy_cache_name:10m inactive=$cache_time max_size=1g;' >> /etc/nginx/cache_config.conf"

    # Test the NGINX configuration and restart the service
    sudo nginx -c /etc/nginx/nginx.conf -t && sudo systemctl restart nginx

    # Create self-signed SSL keys
    echo "Creating self-signed SSL keys..."
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/$cdn_subdomain.key -out /etc/ssl/certs/$cdn_subdomain.crt -subj "/CN=$cdn_subdomain"

    sudo tee /etc/nginx/sites-available/$cdn_subdomain > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $cdn_subdomain;

    # Redirect HTTP to HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $cdn_subdomain;

    # SSL certificate configuration
    ssl_certificate /etc/ssl/certs/$cdn_subdomain.crt;
    ssl_certificate_key /etc/ssl/private/$cdn_subdomain.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH';
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;

    # Enable HTTP/2
    http2_push_preload on;

    # Enable Gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    # CDN cache configuration
    location / {
        proxy_pass $original_url;
        proxy_cache_key "\$scheme://$cdn_subdomain\$request_uri";
        proxy_cache cache_$proxy_cache_name;
        add_header X-Proxy-Cache \$upstream_cache_status;
        expires $cache_time;
        # Add these lines to your existing configuration
        proxy_cache_bypass \$http_x_purge_cache;
        proxy_cache_revalidate on;
        if (\$http_x_purge_cache = "1") {
            add_header X-Cache-Purged "True";
        }
    }

    # NGINX status monitoring configuration
    location /nginx_status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        deny all;
    }
}
EOF


    # Enable CDN subdomain in NGINX
    sudo ln -s /etc/nginx/sites-available/$cdn_subdomain /etc/nginx/sites-enabled/

    # Restart NGINX
    echo "Restarting NGINX..."
    sudo systemctl restart nginx

    # Create Let's Encrypt SSL certificate
    echo "Creating Let's Encrypt SSL certificate..."
    if [[ $cdn_ssl_input = "y" || $original_ssl_input = "y" ]]; then
        sudo certbot --nginx -d $cdn_subdomain -m $email_address --agree-tos --redirect
    fi
}

# Call the function to create NGINX configuration for CDN subdomain
create_cdn_config

if [[ ! -z $custom_cdn_domain ]]; then
    # Set up the custom domain with the same configuration as the CDN subdomain
    cdn_subdomain=$custom_cdn_domain
    create_cdn_config
fi

# Restart NGINX
echo "Restarting NGINX..."
sudo systemctl restart nginx

# Create cron job for renewing Let's Encrypt SSL certificate
echo "Creating Let's Encrypt SSL renewal cron job..."
sudo tee /etc/cron.weekly/renew_ssl_certificates.sh > /dev/null <<EOF
#!/bin/bash
certbot renew --quiet --post-hook "systemctl reload nginx"
EOF

sudo chmod +x /etc/cron.weekly/renew_ssl_certificates.sh

echo "CDN subdomain: https://$cdn_subdomain"
echo "Cache time: $cache_time seconds"
echo ""
echo "User Request -> CDN Subdomain (Caching) -> Origin Server"
echo ""
echo "Configuration completed!"