#!/bin/zsh
set -euo pipefail

identity_name="Seven Local Development"
signing_dir="$HOME/Library/Application Support/Seven/BuildSigning"
keychain="$signing_dir/SevenBuild.keychain-db"
password_file="$signing_dir/keychain-password"

mkdir -p "$signing_dir"
chmod 700 "$signing_dir"

if [[ -f "$keychain" && -f "$password_file" ]]; then
  password="$(<"$password_file")"
  security unlock-keychain -p "$password" "$keychain"
else
  openssl_bin="$(command -v openssl)"
  if [[ -z "$openssl_bin" ]]; then
    print -u2 "OpenSSL is required to create the local signing identity."
    exit 1
  fi

  password="$("$openssl_bin" rand -base64 36 | tr -d '\n')"
  print -rn -- "$password" > "$password_file"
  chmod 600 "$password_file"

  temp_dir="$(mktemp -d /tmp/seven-local-signing.XXXXXX)"
  trap 'rm -rf "$temp_dir"' EXIT

  "$openssl_bin" req -x509 -newkey rsa:2048 -sha256 -nodes \
    -keyout "$temp_dir/key.pem" \
    -out "$temp_dir/cert.pem" \
    -days 3650 \
    -subj "/CN=$identity_name/O=$identity_name" \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,digitalSignature,keyCertSign' \
    -addext 'extendedKeyUsage=codeSigning'

  "$openssl_bin" pkcs12 -export -legacy \
    -inkey "$temp_dir/key.pem" \
    -in "$temp_dir/cert.pem" \
    -out "$temp_dir/identity.p12" \
    -passout "pass:$password" \
    -name "$identity_name"

  security create-keychain -p "$password" "$keychain"
  security unlock-keychain -p "$password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security import "$temp_dir/identity.p12" \
    -k "$keychain" \
    -P "$password" \
    -T /usr/bin/codesign >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "$password" \
    "$keychain" >/dev/null
  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$keychain" \
    "$temp_dir/cert.pem"
fi

typeset -a current_keychains
current_keychains=("${(@f)$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')}")
if (( ${current_keychains[(Ie)$keychain]} == 0 )); then
  security list-keychains -d user -s "$keychain" "${current_keychains[@]}"
fi

identity_hash="$(security find-certificate -a -Z -c "$identity_name" "$keychain" | awk '/SHA-1 hash:/ { print $3; exit }')"
if [[ -z "$identity_hash" ]] || ! security find-identity -v -p codesigning "$keychain" | grep -q "$identity_hash"; then
  print -u2 "The local Seven code-signing identity is unavailable."
  exit 1
fi

print "$identity_hash"
