FROM composer:latest AS composer_stage
FROM php:8.1-fpm-alpine AS base_stage

LABEL org.opencontainers.image.authors="coucou@emi.cool"
LABEL org.opencontainers.image.source="https://github.com/rivals-space/pixelfed-docker"

ARG UID=1000
ARG GID=1000

ARG APCU_VERSION=5.1.21
ARG REDIS_VERSION=5.3.7
ARG IGBINARY_VERSION=3.2.12
ARG ZSTD_VERSION=0.12.0
ARG IMAGICK_VERSION=3.7.0


# Add healthcheck script
COPY conf/php-fpm-healthcheck /usr/local/bin/
RUN set -eux; \
    apk add --no-cache fcgi; \
    set -xe && mkdir -p /usr/local/etc/php-fpm.d; \
    echo "pm.status_path = /status" >> /usr/local/etc/php-fpm.d/zz-docker.conf; \
    chmod +x /usr/local/bin/php-fpm-healthcheck

# Create a dedicated user and group
RUN addgroup -g $UID pixelfed; \
    adduser -u $GID -D -G pixelfed pixelfed

RUN set -eux; \
	apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        fcgi \
        icu-dev \
        libzip-dev \
        zlib-dev \
        freetype \
        freetype-dev \
        libjpeg-turbo \
        libjpeg-turbo-dev \
        libpng \
        libpng-dev \
        libxml2-dev \
        libpq-dev \
        imap-dev \
        krb5-dev \
        gettext-dev \
        zstd-dev \
        imagemagick-dev \
        libtool \
    ; \
    export CFLAGS="$PHP_CFLAGS" CPPFLAGS="$PHP_CPPFLAGS" LDFLAGS="$PHP_LDFLAGS"; \
	\
	docker-php-ext-configure zip; \
    docker-php-ext-configure gd --with-freetype=/usr/include/ --with-jpeg=/usr/include/; \
    docker-php-ext-configure pgsql -with-pgsql=/usr/local/pgsql; \
	docker-php-ext-install -j$(nproc) \
		intl \
        bcmath \
		pcntl \
        zip \
		gd \
        pdo \
        pdo_pgsql \
        pgsql \
        soap \
        imap \
        gettext \
    ; \
    pecl install apcu-${APCU_VERSION}; \
    pecl install \
        zstd-${ZSTD_VERSION} \
        igbinary-${IGBINARY_VERSION} \
        imagick-${IMAGICK_VERSION} \
    ; \
    mkdir -p /usr/src/php/ext && cd /usr/src/php/ext && pecl bundle redis-${REDIS_VERSION} && docker-php-ext-configure redis --enable-redis-igbinary --enable-redis-zstd && docker-php-ext-install -j$(nproc) redis; \
	pecl clear-cache; \
    printf 'extension=igbinary.so\nsession.serialize_handler=igbinary\napc.serializer=igbinary' > /usr/local/etc/php/conf.d/docker-php-ext-igbinary.ini; \
	docker-php-ext-enable \
        zstd \
		apcu \
		opcache \
		intl \
        bcmath \
		pcntl \
		zip \
		gd \
        redis \
        pdo \
        pdo_pgsql \
        soap \
        imap \
        imagick \
    ; \
	\
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)"; \
	apk add --no-cache --virtual .phpexts-rundeps $runDeps; \
	\
	apk del --no-cache  \
        .build-deps \
        icu-dev \
        libzip-dev \
        zlib-dev \
        freetype-dev \
        libjpeg-turbo-dev \
        libpng-dev


RUN ln -s $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini

# Add custom fpm config
COPY conf/fpm/www.conf /usr/local/etc/php-fpm.d/www.conf
COPY conf/ini/pixelfed.ini $PHP_INI_DIR/conf.d/pixelfed.ini


WORKDIR /srv/app

# Add entrypoint
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

# Add composer
COPY --from=composer_stage /usr/bin/composer /usr/bin/composer
ENV PATH="${PATH}:$HOME/.composer/vendor/bin"

# Set web as owner of /srv directory
RUN chown -R pixelfed:pixelfed /srv

# build for production
ENV APP_ENV=prod

USER pixelfed

ENTRYPOINT ["docker-entrypoint"]
CMD ["php-fpm"]



FROM base_stage AS pixelfed_prod

ENV PIXELFED_VERSION="dev"

# download & extract pixelfed source
RUN set -eux; \
    ( \
      if [ "${PIXELFED_VERSION}" = "dev" ] ; \
          then wget https://codeload.github.com/pixelfed/pixelfed/tar.gz/dev -O /tmp/pixelfed.tar.gz; \
          else wget https://github.com/pixelfed/pixelfed/archive/refs/tags/v${PIXELFED_VERSION}.tar.gz -O /tmp/pixelfed.tar.gz; \
        fi \
    ); \
    cd /srv/app && tar --strip-components=1 -zxvf /tmp/pixelfed.tar.gz pixelfed-${PIXELFED_VERSION}; \
    rm /tmp/pixelfed.tar.gz

# install composer dependencies \
RUN set -eux; \
    pwd && ls -alh; \
    composer install --no-ansi --no-interaction --optimize-autoloader; \
    php artisan storage:link; \
    php artisan route:cache; \
    php artisan view:cache
