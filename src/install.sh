#! /bin/sh

set -eux
set -o pipefail

apk update

# install postgres runtime deps for client tools copied from postgres image
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
