#!/usr/bin/env bash
# Publica una versión sin cortar el servicio y permite volver a la anterior.
# Lo ejecuta el agente de GitHub Actions del servidor. Va en el repositorio: .github/scripts/desplegar.sh
#
# Uso:
#   desplegar.sh --tipo angular|drupal --base <dir> --origen <dir> --id <id>
#   desplegar.sh --tipo angular|drupal --base <dir> --revertir
#
# Estructura en el servidor:
#   <base>/releases/<fecha>-<id>   versiones publicadas (se conservan las últimas N)
#   <base>/current                 enlace a la versión activa (se cambia de forma atómica)
#   <base>/shared                  lo que no cambia entre versiones y no está en el repositorio
#       angular: config.json (configuración del ambiente)
#       drupal:  files/ (archivos subidos) y settings.local.php (conexión y secretos)
#   <base>/respaldos               respaldos de la base de datos de Drupal antes de cada despliegue
#
# Variables opcionales:
#   VERSIONES_A_CONSERVAR (5)   CONFIG_ANGULAR (assets/config/config.json)
#   RECARGAR  comando para recargar servicios tras el cambio, p. ej. "sudo systemctl reload php-fpm"
set -euo pipefail
umask 0002

TIPO="" BASE="" ORIGEN="" ID="manual" REVERTIR=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --tipo) TIPO=$2; shift 2 ;;
        --base) BASE=$2; shift 2 ;;
        --origen) ORIGEN=$2; shift 2 ;;
        --id) ID=$2; shift 2 ;;
        --revertir) REVERTIR=1; shift ;;
        *) echo "Parámetro desconocido: $1" >&2; exit 2 ;;
    esac
done
[[ $TIPO == angular || $TIPO == drupal ]] || { echo "Indique --tipo angular o drupal" >&2; exit 2; }
[[ -n $BASE ]] || { echo "Indique --base" >&2; exit 2; }
CONSERVAR=${VERSIONES_A_CONSERVAR:-5}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
mkdir -p "$BASE/releases" "$BASE/shared" "$BASE/respaldos"

# Un solo despliegue a la vez por aplicación.
exec 9>"$BASE/.despliegue.lock"
flock -w 600 9 || { echo "Otro despliegue sigue en curso" >&2; exit 1; }

activa() { readlink -f "$BASE/current" 2>/dev/null || true; }

activar() {  # Cambio atómico del enlace «current».
    ln -sfn "$1" "$BASE/current.nuevo"
    mv -Tf "$BASE/current.nuevo" "$BASE/current"
    log "Versión activa: $(basename "$1")"
}

recargar() { [[ -z ${RECARGAR:-} ]] || bash -c "$RECARGAR"; }

drush() { (cd "$1" && vendor/bin/drush "${@:2}"); }

anterior_a() {
    find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d | sort | awk -v a="$1" '$0 < a' | tail -1
}

if [[ $REVERTIR == 1 ]]; then
    actual=$(activa)
    previa=$(anterior_a "$actual")
    [[ -n $previa ]] || { echo "No hay una versión anterior a $(basename "$actual")" >&2; exit 1; }
    activar "$previa"
    recargar
    if [[ $TIPO == drupal ]]; then
        drush "$BASE/current" cache:rebuild || true
        drush "$BASE/current" state:set system.maintenance_mode 0 --input-format=integer || true
    fi
    log "Revertido. Si el despliegue cambió la base de datos, el respaldo está en $BASE/respaldos."
    exit 0
fi

[[ -d $ORIGEN ]] || { echo "No existe la carpeta de origen $ORIGEN" >&2; exit 2; }
VERSION=$BASE/releases/$(date +%Y%m%d%H%M%S)-$ID
PREVIA=$(activa)
log "Publicando $ID en $VERSION"
mkdir -p "$VERSION"
trap 'echo "Falló antes de activar; se elimina $VERSION" >&2; rm -rf "$VERSION"' ERR
rsync -a --delete --exclude .git "$ORIGEN"/ "$VERSION"/
printf 'id=%s\nfecha=%s\n' "$ID" "$(date -Iseconds)" > "$VERSION/.despliegue"

if [[ $TIPO == angular ]]; then
    destino=$VERSION/${CONFIG_ANGULAR:-assets/config/config.json}
    if [[ -f $BASE/shared/config.json ]]; then
        mkdir -p "$(dirname "$destino")"
        ln -sfn "$BASE/shared/config.json" "$destino"
    fi
    activar "$VERSION"
    trap - ERR
    recargar
else
    sitio=$VERSION/web/sites/default
    mkdir -p "$BASE/shared/files" "$sitio"
    rm -rf "$sitio/files"
    ln -sfn "$BASE/shared/files" "$sitio/files"
    [[ ! -f $BASE/shared/settings.local.php ]] || ln -sfn "$BASE/shared/settings.local.php" "$sitio/settings.local.php"

    if [[ -n $PREVIA && -x $PREVIA/vendor/bin/drush ]]; then
        respaldo=$BASE/respaldos/$(date +%Y%m%d%H%M%S)-antes-de-$ID.sql
        log "Respaldo de la base de datos: $respaldo.gz"
        drush "$PREVIA" sql:dump --gzip --result-file="$respaldo"
        drush "$PREVIA" state:set system.maintenance_mode 1 --input-format=integer
    fi
    trap - ERR

    activar "$VERSION"
    recargar
    # updatedb + config:import + cache:rebuild. Sin configuración exportada, solo updatedb y caché.
    if compgen -G "$VERSION/config/sync/*.yml" >/dev/null; then pasos=(deploy -y); else pasos=(updatedb -y); fi
    if ! drush "$VERSION" "${pasos[@]}"; then
        log "Falló la actualización de Drupal: se vuelve a la versión anterior"
        if [[ -n $PREVIA ]]; then activar "$PREVIA"; recargar; drush "$PREVIA" state:set system.maintenance_mode 0 --input-format=integer || true; fi
        echo "Revise la base de datos: el respaldo previo está en $BASE/respaldos" >&2
        exit 1
    fi
    drush "$VERSION" cache:rebuild
    drush "$VERSION" state:set system.maintenance_mode 0 --input-format=integer
fi

log "Conservando las últimas $CONSERVAR versiones"
find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d | sort | head -n -"$CONSERVAR" | while read -r vieja; do
    [[ $vieja == "$(activa)" ]] || rm -rf "$vieja"
done
find "$BASE/respaldos" -name '*.sql.gz' -mtime +30 -delete 2>/dev/null || true
