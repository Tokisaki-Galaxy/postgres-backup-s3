#! /bin/sh

set -eux
set -o pipefail

apk update

# install runtime deps required by pg_dump/pg_restore copied from postgres:<major>-alpine
# (validated against postgres:18-alpine on 2026-03-29)
apk add libpq zstd-libs lz4-libs openssl krb5-libs libldap libsasl libcom_err keyutils-libs

# install gpg
apk add gnupg

apk add aws-cli

# install go-cron
apk add curl
curl -L https://github.com/ivoronin/go-cron/releases/download/v0.0.5/go-cron_0.0.5_linux_${TARGETARCH}.tar.gz -O
tar xvf go-cron_0.0.5_linux_${TARGETARCH}.tar.gz
rm go-cron_0.0.5_linux_${TARGETARCH}.tar.gz
mv go-cron /usr/local/bin/go-cron
chmod u+x /usr/local/bin/go-cron
apk del curl


# cleanup
rm -rf /var/cache/apk/*
