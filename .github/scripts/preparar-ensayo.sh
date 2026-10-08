#!/usr/bin/env bash
# SOLO PARA EL REPOSITORIO DE ENSAYO DE JMAR: convierte un ejecutor de GitHub (ubuntu-latest) en un
# «servidor» de prueba con Apache (y MySQL para Drupal). En Coopicrédito no se usa: los agentes ya están en los servidores.
# Uso: preparar-ensayo.sh angular|drupal <dir_base>
set -euo pipefail
TIPO=$1 BASE=$2
sudo apt-get update -qq
if [[ $TIPO == angular ]]; then
    sudo apt-get install -y -qq apache2 >/dev/null
    sudo mkdir -p "$BASE" && sudo chown -R "$USER" "$BASE"
    printf '<VirtualHost *:80>\n DocumentRoot %s/current\n <Directory %s/current>\n  Options FollowSymLinks\n  Require all granted\n  FallbackResource /index.html\n </Directory>\n</VirtualHost>\n' "$BASE" "$BASE" | sudo tee /etc/apache2/sites-available/000-default.conf >/dev/null
    mkdir -p "$BASE/shared" && echo '{"ambiente":"ensayo"}' > "$BASE/shared/config.json"
else
    php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    sudo apt-get install -y -qq apache2 "libapache2-mod-php$php_ver" >/dev/null
    sudo a2enmod rewrite >/dev/null
    sudo systemctl start mysql.service
    mysql -uroot -proot -e "CREATE DATABASE IF NOT EXISTS drupal" 2>/dev/null
    sudo mkdir -p "$BASE" && sudo chown -R "$USER" "$BASE"
    printf '<VirtualHost *:80>\n DocumentRoot %s/current/web\n <Directory %s/current/web>\n  Options FollowSymLinks\n  AllowOverride All\n  Require all granted\n </Directory>\n</VirtualHost>\n' "$BASE" "$BASE" | sudo tee /etc/apache2/sites-available/000-default.conf >/dev/null
    mkdir -p "$BASE/shared/files"
    cat > "$BASE/shared/settings.local.php" <<'PHP'
<?php
$databases['default']['default'] = ['driver' => 'mysql', 'database' => 'drupal', 'username' => 'root',
  'password' => 'root', 'host' => '127.0.0.1', 'port' => '3306', 'prefix' => ''];
$settings['hash_salt'] = 'ensayo-sin-valor-real';
$settings['trusted_host_patterns'] = ['^localhost$'];
PHP
    # En el ensayo el sitio no existe: se instala una vez con el artefacto descargado.
    if ! mysql -uroot -proot -N -e "SHOW TABLES FROM drupal" 2>/dev/null | grep -q .; then
        rm -rf /tmp/instalacion && mkdir /tmp/instalacion && tar -xzf ./*.tar.gz -C /tmp/instalacion
        ln -sfn "$BASE/shared/settings.local.php" /tmp/instalacion/web/sites/default/settings.local.php
        (cd /tmp/instalacion && vendor/bin/drush site:install minimal -y --site-name="Intranet ensayo" >/dev/null)
    fi
fi
sudo chmod o+rx "$HOME" "$(dirname "$BASE")" || true
sudo systemctl restart apache2
