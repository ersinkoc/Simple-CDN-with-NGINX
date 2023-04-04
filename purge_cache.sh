#!/bin/bash

# Configuration
proxy_cache_key="\$scheme\$proxy_host\$request_uri"

purge_all() {
    cdn_subdomain="$1"
    proxy_cache_path="/var/cache/nginx/cache_${cdn_subdomain}"
    echo "Purging the entire cache..."
    echo "Cache path: ${proxy_cache_path}"
    sudo rm -rf "${proxy_cache_path}"/*
    echo "Cache purged."
}

purge_path() {
    cdn_subdomain="$1"
    proxy_cache_path="/var/cache/nginx/cache_${cdn_subdomain}"
    url_to_purge="$2"
    cache_key=$(echo -n "${url_to_purge}" | md5sum | awk '{ print $1 }')

    first_level="${cache_key: -1}"
    second_level="${cache_key: -3:2}"

    cache_file_path="$proxy_cache_path/$first_level/$second_level/$cache_key"

    echo "Purging cache for URL: ${url_to_purge}"
    echo "Cache key: ${cache_key}"
    echo "Cache path: ${proxy_cache_path}"
    echo "Cache file path: ${cache_file_path}"
    sudo rm -rf "${cache_file_path}"
    #sudo find "${proxy_cache_path}" -type f -name "${cache_key}_*"
    #sudo find "${proxy_cache_path}" -type f -name "${cache_key}_*" -exec rm -f {} \;
    echo "Cache purged for URL: ${url_to_purge}"
}

# Main script
if [ "$#" -ne 1 ]; then
    echo "Usage:"
    echo "./purge_cache.sh <url>"
    exit 1
fi

url="$1"
cdn_subdomain=$(echo "${url}" | awk -F/ '{print $3}')


# Check if the URL has a path
if echo "${url}" | grep -q "${cdn_subdomain}/[^/]\+"; then
    purge_path "${cdn_subdomain}" "${url}"
else
    purge_all "${cdn_subdomain}"
fi
