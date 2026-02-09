#!/bin/bash
set -e

# === Einstellungen ===
PAPERLESS_USER="paperless"
PAPERLESS_DIR="/opt/paperless"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# === Verzeichnis prüfen ===
if [ ! -d "$PAPERLESS_DIR" ]; then
  echo -e "${RED}Verzeichnis $PAPERLESS_DIR existiert nicht. Abbruch.${NC}"
  exit 1
fi

echo "📁 Wechsle in $PAPERLESS_DIR"
cd "$PAPERLESS_DIR" || exit 1

echo "Überprüfe auf neue Images..."

# Pull neue Images
PULL_OUTPUT=$(sudo -u "$PAPERLESS_USER" docker compose pull 2>&1)

# Check ob Updates verfügbar
if echo "$PULL_OUTPUT" | grep -qi "up to date"; then
    echo -e "${GREEN}Keine Updates verfügbar.${NC}"
    exit 0
fi

# Versionen ermitteln
WEBSERVER_CONTAINER=$(sudo -u "$PAPERLESS_USER" docker compose ps -q webserver 2>/dev/null)
if [ -n "$WEBSERVER_CONTAINER" ]; then
    OLD_IMAGE=$(sudo -u "$PAPERLESS_USER" docker inspect "$WEBSERVER_CONTAINER" --format='{{.Image}}' 2>/dev/null)

    # Versuche Version aus RepoDigests Label zu extrahieren
    OLD_VERSION=$(sudo -u "$PAPERLESS_USER" docker inspect "$OLD_IMAGE" --format='{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null)

    # Fallback: Versuche aus RepoTags
    if [ -z "$OLD_VERSION" ]; then
        OLD_VERSION=$(sudo -u "$PAPERLESS_USER" docker inspect "$WEBSERVER_CONTAINER" --format='{{.Config.Image}}' 2>/dev/null | cut -d':' -f2)
    fi

    # Letzter Fallback: SHA
    [ -z "$OLD_VERSION" ] && OLD_VERSION="sha:$(echo "$OLD_IMAGE" | cut -d':' -f2 | cut -c1-12)"
else
    OLD_VERSION="unbekannt"
fi

# Neue Version ermitteln - aus dem gepullten Image
IMAGE_NAME=$(sudo -u "$PAPERLESS_USER" docker compose config 2>/dev/null | grep 'image:.*paperless-ngx' | head -n1 | awk '{print $2}' | xargs)
if [ -n "$IMAGE_NAME" ]; then
    NEW_VERSION=$(sudo -u "$PAPERLESS_USER" docker inspect "$IMAGE_NAME" --format='{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null)

    # Fallback: Tag aus Image-Name
    [ -z "$NEW_VERSION" ] && NEW_VERSION=$(echo "$IMAGE_NAME" | cut -d':' -f2)
    [ -z "$NEW_VERSION" ] && NEW_VERSION="latest"
else
    NEW_VERSION="latest"
fi

# Prüfe ob Versionen identisch sind
if [ "$OLD_VERSION" = "$NEW_VERSION" ]; then
    echo "Alt/Installiert: $OLD_VERSION"
    echo "Neu/Repo: $NEW_VERSION"
    echo ""
    echo -e "${GREEN}Kein Upgrade notwendig.${NC}"
    exit 0
fi

# Versionen sind unterschiedlich
echo -e "${YELLOW}Neue Version verfügbar!${NC}"
echo "Alt/Installiert: $OLD_VERSION"
echo "Neu/Repo: $NEW_VERSION"
echo ""

# Versionsvergleich (nur wenn beide semantic versioning nutzen)
IS_DOWNGRADE=false
if [[ "$OLD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IFS='.' read -r old_major old_minor old_patch <<< "$OLD_VERSION"
    IFS='.' read -r new_major new_minor new_patch <<< "$NEW_VERSION"

    if [ "$new_major" -lt "$old_major" ] || \
       ([ "$new_major" -eq "$old_major" ] && [ "$new_minor" -lt "$old_minor" ]) || \
       ([ "$new_major" -eq "$old_major" ] && [ "$new_minor" -eq "$old_minor" ] && [ "$new_patch" -lt "$old_patch" ]); then
        IS_DOWNGRADE=true
        echo -e "${RED}WARNUNG: Repo-Version ($NEW_VERSION) ist älter als installierte Version ($OLD_VERSION)!${NC}"
    fi
fi

if [ "$IS_DOWNGRADE" = true ]; then
    read -p "Downgrade wirklich durchführen? [J/n]: " -n 1 -r
else
    read -p "Upgrade durchführen? [J/n]: " -n 1 -r
fi
echo

if [[ ! $REPLY =~ ^[Jj]$ ]] && [[ -n $REPLY ]]; then
    echo "Abbruch."
    exit 0
fi

# Jetzt Rollback vorbereiten
echo "Bereite Rollback vor..."
if [ -n "$WEBSERVER_CONTAINER" ] && [ -n "$OLD_IMAGE" ]; then
    sudo -u "$PAPERLESS_USER" docker tag "$OLD_IMAGE" paperless-backup:rollback 2>/dev/null || true
fi

echo "Stoppe Container..."
sudo -u "$PAPERLESS_USER" docker compose stop
sleep 5

echo "Starte Container mit neuen Images..."
if ! sudo -u "$PAPERLESS_USER" docker compose up -d --no-build 2>&1; then
    echo -e "${RED}Fehler beim Starten!${NC}"
    echo "Führe Rollback durch..."

    sudo -u "$PAPERLESS_USER" docker compose stop
    sudo -u "$PAPERLESS_USER" docker tag paperless-backup:rollback ghcr.io/paperless-ngx/paperless-ngx:latest
    sudo -u "$PAPERLESS_USER" docker compose up -d --no-build

    sudo -u "$PAPERLESS_USER" docker rmi paperless-backup:rollback 2>/dev/null || true
    echo -e "${RED}Zu alten Containern zurückgekehrt.${NC}"
    exit 1
fi

sleep 5

echo ""
echo "Container-Status:"
sudo -u "$PAPERLESS_USER" docker compose ps

# Prüfe ob webserver läuft
if ! sudo -u "$PAPERLESS_USER" docker compose ps | grep -q "webserver.*Up"; then
    echo -e "${RED}Webserver läuft nicht!${NC}"
    echo "Führe Rollback durch..."

    sudo -u "$PAPERLESS_USER" docker compose stop
    sudo -u "$PAPERLESS_USER" docker tag paperless-backup:rollback ghcr.io/paperless-ngx/paperless-ngx:latest
    sudo -u "$PAPERLESS_USER" docker compose up -d --no-build

    sudo -u "$PAPERLESS_USER" docker rmi paperless-backup:rollback 2>/dev/null || true
    echo -e "${RED}Zu alten Containern zurückgekehrt.${NC}"
    exit 1
fi

echo -e "${GREEN}Upgrade erfolgreich!${NC}"

sudo -u "$PAPERLESS_USER" docker rmi paperless-backup:rollback 2>/dev/null || true

echo ""
read -p "Alte Images löschen? [J/n]: " -n 1 -r
echo

if [[ $REPLY =~ ^[Jj]$ ]] || [[ -z $REPLY ]]; then
    echo "Lösche ungenutzte Images..."
    sudo -u "$PAPERLESS_USER" docker image prune -a -f > /dev/null
    echo -e "${GREEN}Cleanup abgeschlossen.${NC}"
else
    echo "Alte Images behalten."
fi
