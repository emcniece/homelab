# Official WordPress image plus the phpredis extension and WP-CLI. Without
# phpredis the Redis Object Cache plugin falls back to Predis (pure PHP),
# which is slower on every cache round-trip. Used by all four WordPress sites
# in apps/.
#
# Built and pushed to ghcr.io/emcniece/wordpress by
# .github/workflows/wordpress-image.yaml, which rebuilds weekly so upstream
# WordPress/PHP security fixes still land.
ARG WORDPRESS_TAG=php8.5-apache
FROM wordpress:${WORDPRESS_TAG}

# Same build-deps pattern as the upstream image: install phpize deps, build,
# then drop only what this layer added.
RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends $PHPIZE_DEPS; \
	pecl install redis; \
	docker-php-ext-enable redis; \
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	rm -rf /var/lib/apt/lists/* /tmp/pear; \
	php -m | grep -qx redis

# WP-CLI, pinned and checksummed (bump both together from
# https://github.com/wp-cli/wp-cli/releases). The phar lives beside a `wp`
# wrapper: `kubectl exec` runs as root, and wp-cli run as root would leave
# root-owned files in wp-content (plugin/theme installs, caches) that Apache
# can't write. The wrapper drops to www-data first, so plain
# `kubectl exec deploy/wordpress -c wordpress -- wp plugin list` works.
# mariadb-client is for `wp db export/import/cli`; it talks to both the
# MariaDB 10.11 sites and kdds' MySQL 5.7. The 11.x client requires a
# verified TLS connection by default, which neither in-cluster server can
# give (MariaDB has no TLS, MySQL 5.7 a self-signed cert), so turn off
# verification: TLS is then used when offered, like WordPress's own
# connection. -core alone lacks mariadb-dump, which `wp db export` needs.
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends mariadb-client; \
	rm -rf /var/lib/apt/lists/*; \
	printf '[client]\nssl-verify-server-cert = off\n' > /etc/mysql/mariadb.conf.d/99-wp-cli.cnf; \
	curl -fsSLo /usr/local/lib/wp-cli.phar "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"; \
	echo "${WP_CLI_SHA512}  /usr/local/lib/wp-cli.phar" | sha512sum -c -; \
	{ \
		echo '#!/bin/sh'; \
		echo 'if [ "$(id -u)" = 0 ]; then'; \
		echo '	exec setpriv --reuid=www-data --regid=www-data --init-groups env HOME=/tmp php /usr/local/lib/wp-cli.phar --path=/var/www/html "$@"'; \
		echo 'fi'; \
		echo 'exec php /usr/local/lib/wp-cli.phar --path=/var/www/html "$@"'; \
	} > /usr/local/bin/wp; \
	chmod +x /usr/local/bin/wp; \
	wp --info
