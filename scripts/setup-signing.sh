#!/usr/bin/env bash
# One-time setup: create the release keystore and store the four signing secrets on GitHub.
# Needs a JDK (keytool) and an authenticated `gh` (gh auth login). Run it on your own machine.
# BACK UP the keystore file and its password: losing them means no update can ever install
# over existing installs.
set -euo pipefail

KEYSTORE="${KEYSTORE:-expressive-cutout-release.jks}"
ALIAS="${ALIAS:-expressive-cutout}"

[[ ! -e "$KEYSTORE" ]] || { echo "$KEYSTORE already exists; refusing to overwrite" >&2; exit 1; }

read -r -s -p "Keystore password (min 6 chars): " PASSWORD; echo
read -r -s -p "Repeat password: " PASSWORD2; echo
[[ "$PASSWORD" == "$PASSWORD2" ]] || { echo "passwords differ" >&2; exit 1; }

keytool -genkeypair -v -keystore "$KEYSTORE" -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 -validity 36500 \
  -storepass "$PASSWORD" -keypass "$PASSWORD" \
  -dname "CN=Expressive Cutout"

base64 -w0 "$KEYSTORE" | gh secret set KEYSTORE_BASE64
gh secret set KEYSTORE_PASSWORD --body "$PASSWORD"
gh secret set KEY_ALIAS --body "$ALIAS"
gh secret set KEY_PASSWORD --body "$PASSWORD"

echo "Done. Back up $KEYSTORE and the password somewhere safe; it is git-ignored."
