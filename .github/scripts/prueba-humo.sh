#!/usr/bin/env bash
# Comprueba que una URL responde con éxito después de un despliegue.
# Uso: prueba-humo.sh <url> [intentos] [segundos-entre-intentos]
set -euo pipefail

URL=${1:?Indique la URL a comprobar}
INTENTOS=${2:-5}
ESPERA=${3:-3}

for ((i = 1; i <= INTENTOS; i++)); do
    codigo=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" || true)
    if [[ $codigo =~ ^(2|3)[0-9][0-9]$ ]]; then
        echo "OK: $URL respondió $codigo"
        exit 0
    fi
    echo "Intento $i/$INTENTOS: $URL respondió ${codigo:-sin respuesta}"
    sleep "$ESPERA"
done
echo "FALLÓ: $URL no respondió correctamente" >&2
exit 1
