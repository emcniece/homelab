# Official WordPress image plus the phpredis extension. Without phpredis the
# Redis Object Cache plugin falls back to Predis (pure PHP), which is slower
# on every cache round-trip. Used by all four WordPress sites in apps/.
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
