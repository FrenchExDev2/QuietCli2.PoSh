# Objectif : Fournir PowerShell 7.6+ Core dans le conteneur Linux de CI sans image personnalisée obligatoire.
set -eu

# Objectif : Réutiliser un runtime déjà compatible dans une image préparée.
if command -v pwsh >/dev/null 2>&1 && pwsh -NoLogo -NoProfile -Command 'if ($PSVersionTable.PSEdition -ne "Core" -or $PSVersionTable.PSVersion -lt [version]"7.6") { exit 1 }' >/dev/null 2>&1; then
    exit 0
fi

# Objectif : Installer les dépendances et sélectionner le binaire correspondant à musl ou glibc.
if [ "$(uname -m)" != "x86_64" ]; then
    echo 'Automatic PowerShell installation supports x64. Supply a prepared PowerShell 7.6+ Core image for another architecture.' >&2
    exit 1
fi
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates curl git icu-libs icu-data-full krb5-libs libgcc libintl libssl3 libstdc++ ncurses-terminfo-base tzdata userspace-rcu zlib
    runtime='linux-musl-x64'
    sha256='f83df6705edaae07db970dcc6c34ad6583d33a2f6199f1b55cdc5354fbb9001c'
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl git libicu74 libssl3t64 libgssapi-krb5-2 libunwind8 zlib1g libsqlite3-0
    runtime='linux-x64'
    sha256='1da6d6d6035d651f20e70ddee7c4c15ac6ab8b9fb40ee92240d91263f28a884b'
else
    echo 'Supply an Alpine/Ubuntu x64 image or an image with PowerShell 7.6+ Core already installed.' >&2
    exit 1
fi

# Objectif : Télécharger la version stable épinglée et vérifier son empreinte officielle avant extraction.
# Empreintes : https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/hashes.sha256
version='7.6.9'
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
archive="$temporary/powershell-$version-$runtime.tar.gz"
curl --fail --silent --show-error --location --max-time 180 \
    --output "$archive" "https://github.com/PowerShell/PowerShell/releases/download/v$version/powershell-$version-$runtime.tar.gz"
printf '%s  %s\n' "$sha256" "$archive" | sha256sum -c -s

# Objectif : Rendre le runtime vérifié disponible aux étapes PowerShell suivantes.
destination="/opt/microsoft/powershell/quietcli-$version"
mkdir -p "$destination"
tar -xzf "$archive" -C "$destination"
chmod +x "$destination/pwsh"
ln -sf "$destination/pwsh" /usr/local/bin/pwsh

# Objectif : Confirmer le runtime installé avant toute qualification ou publication.
pwsh -NoLogo -NoProfile -Command '$ErrorActionPreference="Stop"; if ($PSVersionTable.PSEdition -ne "Core" -or $PSVersionTable.PSVersion -lt [version]"7.6") { throw "QuietCli requires PowerShell 7.6+ Core." }; "PowerShell $($PSVersionTable.PSVersion) Core ready."'
