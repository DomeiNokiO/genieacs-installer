#!/usr/bin/env bash
# =============================================================================
# GenieACS ORI — installer otomatis satu-file untuk Ubuntu/Debian CT
# Cara pakai di CT:
#   curl -fsSL https://raw.githubusercontent.com/DomeiNokiO/genieacs-installer/main/install-genieacs.sh -o install-genieacs.sh
#   chmod +x install-genieacs.sh
#   sudo ./install-genieacs.sh [--version 1.2.16] [--mongo auto|4.4|7.0]
#                              [--open-lan 10.19.12.0/24] [--with-params]
#                              [--admin-pass 'xxx'] [--check-only] [--help]
# Via env (untuk curl | bash):
#   curl -fsSL <url> | sudo GENIEACS_VERSION=1.2.16 OPEN_LAN=10.19.12.0/24 WITH_PARAMS=1 bash
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

GENIEACS_VERSION="${GENIEACS_VERSION:-latest}"
MONGO_WANT="${MONGO_WANT:-auto}"     # auto|4.4|7.0
OPEN_LAN="${OPEN_LAN:-}"             # contoh: 10.19.12.0/24
WITH_PARAMS="${WITH_PARAMS:-0}"      # 1 = restore koleksi parameter paimo54
ADMIN_PASS="${ADMIN_PASS:-}"         # opsional: set password admin via Mongo
CHECK_ONLY=0
MONGO_SERIES=""
MONGO_SUITE=""
LOG="/var/log/genieacs-install.log"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  echo "Opsi:"
  echo "  --version X      versi npm genieacs (default: latest, stabil: 1.2.16)"
  echo "  --mongo X        auto|4.4|7.0 (default: auto dari AVX)"
  echo "  --open-lan CIDR  aktifkan UFW, buka 7547/7557/7567/3000 hanya dari CIDR"
  echo "  --with-params    restore parameter paimo54 (backup dulu, aman)"
  echo "  --admin-pass P   set password user admin setelah install"
  echo "  --check-only     hanya health-check, tanpa install"
  echo "  --help           tampilkan bantuan ini"
}

for arg in "$@"; do
  case "$arg" in
    --version=*) GENIEACS_VERSION="${arg#*=}" ;;
    --version) GENIEACS_VERSION="${2:-latest}" ;;
    --mongo=*) MONGO_WANT="${arg#*=}" ;;
    --mongo) MONGO_WANT="${2:-auto}" ;;
    --open-lan=*) OPEN_LAN="${arg#*=}" ;;
    --open-lan) OPEN_LAN="${2:-}" ;;
    --with-params) WITH_PARAMS=1 ;;
    --admin-pass=*) ADMIN_PASS="${arg#*=}" ;;
    --admin-pass) ADMIN_PASS="${2:-}" ;;
    --check-only) CHECK_ONLY=1 ;;
    --help|-h) usage; exit 0 ;;
  esac
done

say() { echo; echo "== $* =="; }
log() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }

[ "$(id -u)" = "0" ] || { echo "ERROR: jalankan sebagai root (sudo)"; exit 1; }

health_check() {
  say "STATUS LAYANAN"
  systemctl is-active mongod genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui || true
  say "PORT LISTEN"
  ss -tln | grep -E ':(7547|7557|7567|3000|27017)\b' || echo "ADA PORT BELUM TERBUKA"
  say "HTTP"
  curl -s -o /dev/null -w 'UI  : %{http_code}\n' http://127.0.0.1:3000/ || true
  curl -s -o /dev/null -w 'NBI : %{http_code}\n' http://127.0.0.1:7557/devices || true
}

if [ "$CHECK_ONLY" = "1" ]; then health_check; exit 0; fi

exec > >(tee -a "$LOG") 2>&1
log "Mulai install GenieACS ori | versi=$GENIEACS_VERSION mongo=$MONGO_WANT lan=${OPEN_LAN:-none} params=$WITH_PARAMS"

# ---- 1. deteksi OS -----------------------------------------------------------
. /etc/os-release
case "$ID" in
  ubuntu)
    case "$VERSION_CODENAME" in focal|jammy|noble|oracular) : ;;
      *) echo "ERROR: Ubuntu $VERSION_CODENAME belum didukung (focal/jammy/noble)"; exit 1 ;; esac ;;
  debian)
    case "$VERSION_CODENAME" in bullseye|bookworm|trixie) : ;;
      *) echo "ERROR: Debian $VERSION_CODENAME belum didukung"; exit 1 ;; esac ;;
  *) echo "ERROR: hanya Ubuntu/Debian"; exit 1 ;;
esac

# ---- 2. deteksi AVX -> MongoDB ----------------------------------------------
if [ "$MONGO_WANT" = "auto" ]; then
  if grep -q -m1 avx /proc/cpuinfo 2>/dev/null; then
    MONGO_SERIES="7.0"; MONGO_SUITE="$VERSION_CODENAME"
    say "CPU punya AVX -> MongoDB 7.0"
  else
    MONGO_SERIES="4.4"; MONGO_SUITE="focal"
    say "CPU TANPA AVX (LXC/tua) -> MongoDB 4.4 (5.0+ butuh AVX)"
  fi
else
  MONGO_SERIES="$MONGO_WANT"
  MONGO_SUITE="$VERSION_CODENAME"
  [ "$MONGO_SERIES" = "4.4" ] && MONGO_SUITE="focal"
fi
say "Deteksi: $PRETTY_NAME | arch $(uname -m) | Mongo $MONGO_SERIES ($MONGO_SUITE)"

apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg logrotate jq git

# ---- 3. Node.js 22 LTS -------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  say "[3/8] Install Node.js 22 (NodeSource)"
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  apt-get install -y -qq nodejs
fi
say "Node $(node -v) / npm $(npm -v)"

# ---- 4. libssl1.1 untuk Mongo 4.4 --------------------------------------------
if [ "$MONGO_SERIES" = "4.4" ] && ! ldconfig -p | grep -q 'libssl.so.1.1'; then
  say "[4/8] Install libssl1.1 (focal) - dibutuhkan MongoDB 4.4"
  F=$(curl -fsSL http://security.ubuntu.com/ubuntu/pool/main/o/openssl/ \
      | grep -oE 'libssl1\.1_[0-9][^"]*_amd64\.deb' | sort -uV | tail -1)
  [ -n "$F" ] || { echo "ERROR: libssl1.1 tidak ditemukan di pool"; exit 1; }
  curl -fsSL -o /tmp/libssl1.1.deb "http://security.ubuntu.com/ubuntu/pool/main/o/openssl/${F}"
  dpkg -i /tmp/libssl1.1.deb
fi

# ---- 5. MongoDB ---------------------------------------------------------------
if ! command -v mongod >/dev/null 2>&1; then
  say "[5/8] Install MongoDB $MONGO_SERIES"
  curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGO_SERIES}.asc" \
    | gpg --dearmor --yes -o "/usr/share/keyrings/mongodb-server-${MONGO_SERIES}.gpg"
  echo "deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-${MONGO_SERIES}.gpg ] https://repo.mongodb.org/apt/${ID} ${MONGO_SUITE}/mongodb-org/${MONGO_SERIES} multiverse" \
    > "/etc/apt/sources.list.d/mongodb-org-${MONGO_SERIES}.list"
  apt-get update -qq
  apt-get install -y -qq mongodb-org
fi
systemctl enable --now mongod
sleep 2
systemctl is-active mongod || { echo "ERROR: mongod tidak aktif"; exit 1; }

# ---- 6. GenieACS ---------------------------------------------------------------
if ! command -v genieacs-cwmp >/dev/null 2>&1; then
  say "[6/8] Install GenieACS (npm) - versi: $GENIEACS_VERSION"
  npm install -g "genieacs@${GENIEACS_VERSION}"
fi
GBIN="$(dirname "$(command -v genieacs-cwmp)")"
say "GenieACS bins: $GBIN/genieacs-{cwmp,nbi,fs,ui}"

id -u genieacs >/dev/null 2>&1 || useradd --system --no-create-home --user-group genieacs
mkdir -p /opt/genieacs/ext /var/log/genieacs
chown genieacs:genieacs /opt/genieacs/ext /var/log/genieacs

ENV=/opt/genieacs/genieacs.env
if [ ! -f "$ENV" ]; then
  cat > "$ENV" <<'EOF'
GENIEACS_CWMP_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-cwmp-access.log
GENIEACS_NBI_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-nbi-access.log
GENIEACS_FS_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-fs-access.log
GENIEACS_UI_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-ui-access.log
GENIEACS_DEBUG_FILE=/var/log/genieacs/genieacs-debug.yaml
NODE_OPTIONS=--enable-source-maps
GENIEACS_EXT_DIR=/opt/genieacs/ext
EOF
fi
grep -q '^GENIEACS_UI_JWT_SECRET=' "$ENV" || \
  node -e "console.log('GENIEACS_UI_JWT_SECRET='+require('crypto').randomBytes(128).toString('hex'))" >> "$ENV"
chown genieacs:genieacs "$ENV"
chmod 600 "$ENV"

# ---- 7. systemd + logrotate ------------------------------------------------------
for svc in cwmp nbi fs ui; do
  DESC="$(echo "$svc" | tr 'a-z' 'A-Z')"
  cat > "/etc/systemd/system/genieacs-${svc}.service" <<EOF
[Unit]
Description=GenieACS ${DESC}
After=network.target mongod.service

[Service]
User=genieacs
EnvironmentFile=/opt/genieacs/genieacs.env
ExecStart=${GBIN}/genieacs-${svc}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
done

cat > /etc/logrotate.d/genieacs <<'EOF'
/var/log/genieacs/*.log /var/log/genieacs/*.yaml {
    daily
    rotate 30
    compress
    delaycompress
    dateext
}
EOF

systemctl daemon-reload
for svc in cwmp nbi fs ui; do systemctl enable --now "genieacs-${svc}"; done
sleep 6

# ---- 8. firewall opsional ---------------------------------------------------------
if [ -n "$OPEN_LAN" ]; then
  say "[8/8] UFW: deny incoming; buka 22 + port ACS ($OPEN_LAN saja)"
  apt-get install -y -qq ufw >/dev/null 2>&1 || true
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment "SSH"
  for p in 7547 7557 7567 3000; do ufw allow from "$OPEN_LAN" to any port "$p" comment "GenieACS $p"; done
  ufw --force enable
fi

# ---- 9. parameter paimo54 (opsional) ------------------------------------------------
if [ "$WITH_PARAMS" = "1" ]; then
  say "Restore parameter paimo54 (backup dulu)"
  mkdir -p /var/backups/genieacs
  mongodump --db genieacs --gzip --archive="/var/backups/genieacs/pre-$(date +%F).archive.gz" || true
  mkdir -p /var/backups/genieacs/users-only
  mongodump --db genieacs --collection users --out /var/backups/genieacs/users-only || true
  rm -rf /tmp/parameter
  git clone --depth 1 https://github.com/paimo54/parameter.git /tmp/parameter
  mongorestore --db genieacs --drop /tmp/parameter
  # kembalikan users bila admin hilang
  if [ -f /var/backups/genieacs/users-only/genieacs/users.bson ]; then
    mongorestore --db genieacs --collection users --drop /var/backups/genieacs/users-only/genieacs/users.bson || true
  fi
fi

# ---- 10. password admin opsional ------------------------------------------------------
if [ -n "$ADMIN_PASS" ]; then
  say "Set password admin"
  mongosh genieacs --quiet --eval "db.users.updateOne({username:'admin'},{\$set:{password:'$ADMIN_PASS'}})" 2>/dev/null \
  || mongo genieacs --quiet --eval "db.users.updateOne({username:'admin'},{\$set:{password:'$ADMIN_PASS'}})" || true
fi

health_check
echo
echo "SELESAI. Langkah berikut:"
echo "  1. Buka http://<host>:3000 (tunnel: ssh -L 13000:127.0.0.1:3000 root@<host>)"
echo "  2. Wizard pertama -> centang semua -> ABRACADABRA! -> login admin/admin"
echo "  3. GANTI password admin segera (UI -> Admin -> Users)."
echo "  4. JWT secret acak di $ENV (chmod 600)."
echo "  5. Log install: $LOG"
