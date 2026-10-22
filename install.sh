#!/usr/bin/env bash
# =============================================================================
# GenieACS ORI — installer otomatis satu-file untuk Ubuntu/Debian CT
#
# Cara pakai di CT (sebagai root):
#   curl -fsSL https://raw.githubusercontent.com/DomeiNokiO/genieacs-installer/master/install.sh -o install.sh
#   chmod +x install.sh
#   sudo ./install.sh [--version 1.2.16] [--mongo auto|4.4|7.0|8.0]
#                     [--open-lan 10.19.12.0/24] [--ssh-port 22] [--with-params]
#                     [--admin-pass 'xxx'] [--check-only] [--help]
#
# Via env (untuk curl | bash):
#   curl -fsSL <url> | sudo GENIEACS_VERSION=1.2.16 OPEN_LAN=10.19.12.0/24 WITH_PARAMS=1 bash
# =============================================================================
[ -n "${BASH_VERSION:-}" ] || { echo "ERROR: jalankan dengan bash, bukan sh" >&2; exit 1; }
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
umask 022

GENIEACS_VERSION="${GENIEACS_VERSION:-latest}"
MONGO_WANT="${MONGO_WANT:-auto}"                # auto|4.4|7.0|8.0
MONGO_SUITE_OVERRIDE="${MONGO_SUITE_OVERRIDE:-}" # paksa codename suite repo MongoDB
OPEN_LAN="${OPEN_LAN:-}"                        # contoh: 10.19.12.0/24
SSH_PORT="${SSH_PORT:-auto}"                    # auto = deteksi dari sshd
WITH_PARAMS="${WITH_PARAMS:-0}"                 # 1 = restore koleksi parameter paimo54
ADMIN_PASS="${ADMIN_PASS:-}"                    # opsional: set password admin (di-hash)
CHECK_ONLY="${CHECK_ONLY:-0}"

MONGO_SERIES=""
MONGO_SUITE=""
MONGO_DISTRO=""
ENV_FILE=/opt/genieacs/genieacs.env
LOG=/var/log/genieacs-install.log
TMPFILES=()

is_true() { case "${1,,}" in 1|true|yes|y|on) return 0 ;; *) return 1 ;; esac; }

cleanup() {
  local f
  for f in "${TMPFILES[@]}"; do
    [ -n "$f" ] && rm -f "$f"
  done
  return 0
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo; echo "== $* =="; }
log() { echo "[$(date +%T)] $*"; }   # stdout sudah di-tee ke $LOG

usage() {
  cat <<'USAGE'
GenieACS Auto Installer (Ubuntu/Debian)

Opsi:
  --version X        versi npm genieacs (default: latest, stabil: 1.2.16)
  --mongo X          auto|4.4|7.0|8.0 (default: auto dari deteksi AVX)
  --mongo-suite X    paksa codename repo MongoDB (mis. bookworm); untuk kasus khusus
  --open-lan CIDR    aktifkan UFW: tolak semua masuk, buka port ACS hanya dari CIDR
  --ssh-port X       port SSH yang tetap dibuka saat UFW aktif (default: auto-deteksi)
  --with-params      restore parameter paimo54 (DB di-backup dulu)
  --admin-pass P     set password user admin (disimpan sebagai hash PBKDF2-SHA512)
  --check-only       hanya health-check, tanpa mengubah instalasi
  --help             tampilkan bantuan ini

Contoh:
  ./install.sh --version 1.2.16 --with-params --open-lan 192.168.100.0/24
USAGE
}

while [ $# -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --version|--mongo|--mongo-suite|--open-lan|--admin-pass|--ssh-port)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$arg butuh nilai (lihat --help)"
      case "$arg" in
        --version) GENIEACS_VERSION="$2" ;;
        --mongo) MONGO_WANT="$2" ;;
        --mongo-suite) MONGO_SUITE_OVERRIDE="$2" ;;
        --open-lan) OPEN_LAN="$2" ;;
        --admin-pass) ADMIN_PASS="$2" ;;
        --ssh-port) SSH_PORT="$2" ;;
      esac
      shift 2 ;;
    --version=*) GENIEACS_VERSION="${arg#*=}"; shift ;;
    --mongo=*) MONGO_WANT="${arg#*=}"; shift ;;
    --mongo-suite=*) MONGO_SUITE_OVERRIDE="${arg#*=}"; shift ;;
    --open-lan=*) OPEN_LAN="${arg#*=}"; shift ;;
    --admin-pass=*) ADMIN_PASS="${arg#*=}"; shift ;;
    --ssh-port=*) SSH_PORT="${arg#*=}"; shift ;;
    --with-params) WITH_PARAMS=1; shift ;;
    --check-only) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "opsi tidak dikenal: $arg (lihat --help)" ;;
  esac
done

case "$MONGO_WANT" in
  auto|4.4|7.0|8.0) : ;;
  *) die "--mongo hanya menerima auto|4.4|7.0|8.0" ;;
esac
case "$SSH_PORT" in
  auto) : ;;
  ''|*[!0-9]*) die "--ssh-port harus berupa angka atau auto" ;;
  *) [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || die "--ssh-port di luar rentang 1-65535" ;;
esac
if [ -n "$OPEN_LAN" ]; then
  if ! [[ "$OPEN_LAN" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
    die "--open-lan harus CIDR IPv4, contoh: 10.19.12.0/24"
  fi
fi

health_check() {
  local svc out
  say "STATUS LAYANAN"
  for svc in mongod genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui; do
    printf '  %-16s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"
  done

  say "PORT LISTEN"
  ss -tln 2>/dev/null | grep -E ':(7547|7557|7567|3000|27017)\b' || echo "  ADA PORT BELUM TERBUKA"

  say "HTTP"
  curl -s -o /dev/null --max-time 5 -w '  UI  : %{http_code}\n' http://127.0.0.1:3000/ || true
  curl -s -o /dev/null --max-time 5 -w '  NBI : %{http_code}\n' http://127.0.0.1:7557/devices || true

  say "MONGODB"
  if command -v mongosh >/dev/null 2>&1; then
    out="$(mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null || true)"
  elif command -v mongo >/dev/null 2>&1; then
    out="$(mongo --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null || true)"
  else
    out=""
  fi
  echo "  ping: ${out:-gagal/tidak ada shell mongo}"
}

if is_true "$CHECK_ONLY"; then health_check; exit 0; fi

[ "$(id -u)" = "0" ] || die "jalankan sebagai root (sudo)"

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
log "Mulai install GenieACS | versi=$GENIEACS_VERSION mongo=$MONGO_WANT lan=${OPEN_LAN:-none} params=$WITH_PARAMS"

# ---- 1. deteksi OS -----------------------------------------------------------
. /etc/os-release
case "$ID" in
  ubuntu)
    case "$VERSION_CODENAME" in
      focal|jammy|noble) : ;;
      *) die "Ubuntu $VERSION_CODENAME belum didukung (focal/jammy/noble)" ;;
    esac ;;
  debian)
    case "$VERSION_CODENAME" in
      bullseye|bookworm|trixie) : ;;
      *) die "Debian $VERSION_CODENAME belum didukung (bullseye/bookworm/trixie)" ;;
    esac ;;
  *) die "hanya Ubuntu/Debian yang didukung" ;;
esac

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64|arm64) : ;; *) die "arsitektur $ARCH belum didukung" ;; esac

# ---- 2. deteksi AVX + pilih versi/suite MongoDB yang repo-nya benar-benar ada --
say "Deteksi: $PRETTY_NAME | arch $ARCH"

mongo_release_ok() {
  local distro="$1" suite="$2" series="$3"
  curl -fsSL -o /dev/null --max-time 20 \
    "https://repo.mongodb.org/apt/${distro}/dists/${suite}/mongodb-org/${series}/Release" 2>/dev/null
}

choose_mongo() {
  local avx=0 series suite cands=()
  curl -fsS -o /dev/null --max-time 15 https://repo.mongodb.org/ \
    || die "tidak bisa mengakses repo.mongodb.org (periksa koneksi/DNS/proxy)"
  if grep -qm1 '\bavx\b' /proc/cpuinfo 2>/dev/null; then avx=1; fi

  case "$MONGO_WANT" in
    auto|4.4|7.0|8.0) : ;;
    *) die "--mongo hanya menerima auto|4.4|7.0|8.0" ;;
  esac

  if [ "$MONGO_WANT" = "auto" ]; then
    if [ "$avx" = "1" ]; then
      cands=(7.0 8.0)
    else
      cands=(4.4)
    fi
  else
    if [ "$avx" != "1" ] && [ "$MONGO_WANT" != "4.4" ]; then
      die "CPU tanpa AVX: MongoDB $MONGO_WANT akan crash saat start. Pakai --mongo 4.4."
    fi
    cands=("$MONGO_WANT")
  fi

  for series in "${cands[@]}"; do
    if [ -n "$MONGO_SUITE_OVERRIDE" ]; then
      suite="$MONGO_SUITE_OVERRIDE"
    elif [ "$series" = "4.4" ]; then
      suite="$([ "$ID" = "debian" ] && echo buster || echo focal)"
    else
      suite="$VERSION_CODENAME"
    fi
    if mongo_release_ok "$ID" "$suite" "$series"; then
      MONGO_SERIES="$series"; MONGO_SUITE="$suite"; MONGO_DISTRO="$ID"
      return 0
    fi
    echo "  (repo MongoDB $series untuk $ID/$suite tidak tersedia, coba kandidat berikutnya)"
  done

  die "tidak ada repo MongoDB resmi untuk ${PRETTY_NAME:-$ID $VERSION_CODENAME}.
  Kandidat yang dicoba: ${cands[*]}.
  Solusi: pakai CT Ubuntu 22.04, atau tentukan sendiri dengan
  --mongo <4.4|7.0|8.0> --mongo-suite <codename>."
}

choose_mongo
if [ "$MONGO_WANT" = "auto" ]; then
  if [ "$MONGO_SERIES" = "7.0" ]; then
    say "CPU punya AVX -> MongoDB 7.0"
  elif [ "$MONGO_SERIES" = "8.0" ]; then
    say "CPU punya AVX -> MongoDB 8.0 (repo 7.0 tidak tersedia untuk $VERSION_CODENAME)"
  else
    say "CPU TANPA AVX (LXC/tua) -> MongoDB 4.4 (5.0+ butuh AVX)"
  fi
else
  say "MongoDB $MONGO_SERIES dipaksa lewat --mongo"
fi
say "MongoDB terpilih: $MONGO_SERIES | repo $MONGO_DISTRO/$MONGO_SUITE"

apt-get update -qq || die "apt-get update gagal (cek koneksi/DNS/repo)"
apt-get install -y -qq curl ca-certificates gnupg logrotate git || die "gagal install paket dasar"

# ---- 3. Node.js LTS (22) ------------------------------------------------------
install_node() {
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq || die "apt-get update gagal (NodeSource)"
  apt-get install -y -qq nodejs || die "gagal install Node.js 22"
}

if ! command -v node >/dev/null 2>&1; then
  say "[3/8] Install Node.js 22 (NodeSource)"
  install_node
else
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [ "${NODE_MAJOR:-0}" -lt 18 ]; then
    say "[3/8] Node.js $NODE_MAJOR terlalu lama, upgrade ke Node.js 22"
    install_node
  fi
fi
# npm ikut terpasang dari paket NodeSource; jaga-jaga kalau node ada tanpa npm
command -v npm >/dev/null 2>&1 || install_node
say "Node $(node -v) / npm $(npm -v)"

# ---- 4. libssl1.1 untuk Mongo 4.4 --------------------------------------------
if [ "$MONGO_SERIES" = "4.4" ] && ! ldconfig -p | grep -q 'libssl\.so\.1\.1'; then
  [ "$ARCH" = "amd64" ] || die "MongoDB 4.4 butuh libssl1.1; skrip ini hanya menyediakannya untuk amd64"
  say "[4/8] Install libssl1.1 (focal) - dibutuhkan MongoDB 4.4"
  F="$(curl -fsSL http://security.ubuntu.com/ubuntu/pool/main/o/openssl/ \
       | grep -oE 'libssl1\.1_[0-9][^"]*_amd64\.deb' | sort -uV | tail -1 || true)"
  [ -n "$F" ] || die "libssl1.1 tidak ditemukan di pool Ubuntu"
  curl -fsSL -o /tmp/libssl1.1.deb "http://security.ubuntu.com/ubuntu/pool/main/o/openssl/${F}" \
    || die "gagal unduh libssl1.1"
  TMPFILES+=(/tmp/libssl1.1.deb)
  dpkg -i /tmp/libssl1.1.deb || die "gagal install libssl1.1"
fi

# ---- 5. MongoDB ---------------------------------------------------------------
if ! command -v mongod >/dev/null 2>&1; then
  say "[5/8] Install MongoDB $MONGO_SERIES"
  if [ "$MONGO_DISTRO" = "ubuntu" ]; then MONGO_COMPONENT=multiverse; else MONGO_COMPONENT=main; fi
  MONGO_KEYRING="/usr/share/keyrings/mongodb-server-${MONGO_SERIES}.gpg"
  MONGO_LIST="/etc/apt/sources.list.d/mongodb-org-${MONGO_SERIES}.list"

  curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGO_SERIES}.asc" \
    | gpg --dearmor --yes -o "$MONGO_KEYRING" || die "gagal unduh GPG key MongoDB $MONGO_SERIES"

  echo "deb [ arch=${ARCH} signed-by=${MONGO_KEYRING} ] https://repo.mongodb.org/apt/${MONGO_DISTRO} ${MONGO_SUITE}/mongodb-org/${MONGO_SERIES} ${MONGO_COMPONENT}" \
    > "$MONGO_LIST"

  if ! apt-get update -qq; then
    echo "--- isi $MONGO_LIST ---"
    cat "$MONGO_LIST"
    rm -f "$MONGO_LIST"
    die "apt-get update gagal setelah menambah repo MongoDB (repo sudah dihapus agar tidak merusak apt)"
  fi
  apt-get install -y -qq mongodb-org || die "gagal install mongodb-org $MONGO_SERIES"
else
  INSTALLED_MONGO="$(mongod --version 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i ~ /^v[0-9]/){sub(/^v/,"",$i); print $i; exit}}' || true)"
  say "MongoDB sudah terpasang (${INSTALLED_MONGO:-versi tidak terbaca}), lewati install"
  case "$INSTALLED_MONGO" in
    "$MONGO_SERIES"|"$MONGO_SERIES".*) : ;;
    *) echo "  CATATAN: MongoDB terpasang beda dari pilihan skrip ($MONGO_SERIES); versi lama dipertahankan" ;;
  esac
fi

systemctl enable --now mongod >/dev/null 2>&1 || true
READY=0
for _ in $(seq 1 30); do
  if systemctl is-active --quiet mongod; then READY=1; break; fi
  sleep 1
done
[ "$READY" = "1" ] || die "mongod tidak aktif setelah 30 detik (cek: journalctl -u mongod -n 50)"
say "MongoDB $(mongod --version 2>/dev/null | awk 'NR==1')"

# ---- 6. GenieACS ---------------------------------------------------------------
if ! command -v genieacs-cwmp >/dev/null 2>&1; then
  say "[6/8] Install GenieACS (npm) - versi: $GENIEACS_VERSION"
  npm install -g "genieacs@${GENIEACS_VERSION}" || die "gagal install genieacs dari npm"
else
  CURRENT_ACS="$(npm ls -g --depth=0 genieacs 2>/dev/null | sed -n 's/.*genieacs@\([0-9][^ ]*\).*/\1/p' | head -1 || true)"
  if [ "$GENIEACS_VERSION" != "latest" ] && [ -n "$CURRENT_ACS" ] && [ "$CURRENT_ACS" != "$GENIEACS_VERSION" ]; then
    say "[6/8] Ganti GenieACS $CURRENT_ACS -> $GENIEACS_VERSION"
    npm install -g "genieacs@${GENIEACS_VERSION}" || die "gagal upgrade genieacs"
  else
    say "[6/8] GenieACS sudah terpasang${CURRENT_ACS:+ ($CURRENT_ACS)}, lewati npm install"
  fi
fi
GBIN="$(dirname "$(command -v genieacs-cwmp)")"
say "GenieACS bins: $GBIN/genieacs-{cwmp,nbi,fs,ui}"

id -u genieacs >/dev/null 2>&1 || useradd --system --no-create-home --user-group genieacs
mkdir -p /opt/genieacs/ext /var/log/genieacs
chown genieacs:genieacs /opt/genieacs/ext /var/log/genieacs

if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<'EOF'
GENIEACS_CWMP_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-cwmp-access.log
GENIEACS_NBI_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-nbi-access.log
GENIEACS_FS_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-fs-access.log
GENIEACS_UI_ACCESS_LOG_FILE=/var/log/genieacs/genieacs-ui-access.log
GENIEACS_DEBUG_FILE=/var/log/genieacs/genieacs-debug.yaml
NODE_OPTIONS=--enable-source-maps
GENIEACS_EXT_DIR=/opt/genieacs/ext
EOF
fi
grep -q '^GENIEACS_UI_JWT_SECRET=' "$ENV_FILE" || \
  node -e "console.log('GENIEACS_UI_JWT_SECRET='+require('crypto').randomBytes(128).toString('hex'))" >> "$ENV_FILE"
chown genieacs:genieacs "$ENV_FILE"
chmod 600 "$ENV_FILE"

# ---- 7. systemd + logrotate ------------------------------------------------------
for svc in cwmp nbi fs ui; do
  SVC_UPPER="$(echo "$svc" | tr '[:lower:]' '[:upper:]')"
  cat > "/etc/systemd/system/genieacs-${svc}.service" <<EOF
[Unit]
Description=GenieACS ${SVC_UPPER}
After=network.target mongod.service
Wants=mongod.service

[Service]
User=genieacs
EnvironmentFile=${ENV_FILE}
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
for svc in cwmp nbi fs ui; do
  systemctl enable --now "genieacs-${svc}" \
    || die "gagal start genieacs-${svc} (cek: journalctl -u genieacs-${svc} -n 50)"
done
sleep 6

# ---- 8. firewall opsional (tanpa menghapus rules yang sudah ada) ------------------
detect_ssh_port() {
  local p=""
  if command -v sshd >/dev/null 2>&1; then
    p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)"
  fi
  echo "${p:-22}"
}
if [ "$SSH_PORT" = "auto" ]; then SSH_PORT="$(detect_ssh_port)"; fi

if [ -n "$OPEN_LAN" ]; then
  say "[8/8] UFW: default deny incoming; buka SSH $SSH_PORT + port ACS dari $OPEN_LAN"
  command -v ufw >/dev/null 2>&1 || apt-get install -y -qq ufw || die "gagal install ufw"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow "${SSH_PORT}/tcp" comment "SSH" >/dev/null
  for p in 7547 7557 7567 3000; do
    ufw allow from "$OPEN_LAN" to any port "$p" proto tcp comment "GenieACS $p" >/dev/null
  done
  ufw --force enable >/dev/null || die "gagal mengaktifkan UFW"
  ufw status verbose || true
else
  log "UFW tidak diaktifkan (tanpa --open-lan)"
fi

# ---- 9. parameter paimo54 (opsional) ------------------------------------------------
if is_true "$WITH_PARAMS"; then
  say "Restore parameter paimo54 (backup dulu)"
  command -v mongorestore >/dev/null 2>&1 || die "mongorestore tidak ada (paket mongodb-org-tools)"

  mkdir -p /var/backups/genieacs
  mongodump --db genieacs --gzip --archive="/var/backups/genieacs/pre-$(date +%F-%H%M).archive.gz" \
    || echo "  PERINGATAN: backup penuh gagal, lanjut (backup users tetap dicoba)"

  USERS_BACKUP=/var/backups/genieacs/users-only/genieacs/users.bson
  rm -rf /var/backups/genieacs/users-only
  mongodump --db genieacs --collection users --out /var/backups/genieacs/users-only >/dev/null 2>&1 || true

  rm -rf /tmp/parameter
  git clone --depth 1 https://github.com/paimo54/parameter.git /tmp/parameter \
    || die "gagal clone repo parameter paimo54"

  DUMPDIR="$(find /tmp/parameter -maxdepth 3 -name '*.bson' -printf '%h\n' 2>/dev/null | sort -u | head -1 || true)"
  [ -n "$DUMPDIR" ] || die "tidak ada file *.bson di repo parameter (format dump berubah?)"
  say "Restore dump dari $DUMPDIR"
  mongorestore --db genieacs --drop "$DUMPDIR" || die "mongorestore gagal"

  # dump ikut menimpa koleksi users, jadi kembalikan user dari backup
  if [ -f "$USERS_BACKUP" ]; then
    mongorestore --db genieacs --collection users --drop "$USERS_BACKUP" \
      || echo "  PERINGATAN: gagal restore users; login admin mungkin memakai data dari dump"
  else
    echo "  PERINGATAN: backup users tidak ditemukan; jika login admin gagal, restore dari backup penuh di /var/backups/genieacs/"
  fi

  for svc in cwmp nbi fs ui; do systemctl restart "genieacs-${svc}" >/dev/null 2>&1 || true; done
fi

# ---- 10. password admin opsional (hash PBKDF2-SHA512, sama seperti GenieACS) --------
set_admin_password() {
  local pw="$1" tmpjs out=""
  command -v node >/dev/null 2>&1 || die "node tidak ditemukan untuk menghitung hash password"

  tmpjs="$(mktemp /tmp/genieacs-adminpass.XXXXXX.js)"
  TMPFILES+=("$tmpjs")

  GENIEACS_ADMIN_PASS="$pw" GENIEACS_ADMIN_JS="$tmpjs" node -e '
    const fs = require("fs");
    const crypto = require("crypto");
    const salt = crypto.randomBytes(64).toString("hex");
    const hash = crypto.pbkdf2Sync(process.env.GENIEACS_ADMIN_PASS, salt, 10000, 128, "sha512").toString("hex");
    const update = "{ $set: { salt: " + JSON.stringify(salt) + ", password: " + JSON.stringify(hash) + " } }";
    const js = "const u = " + update + ";\n" +
      "let r = db.users.updateOne({ _id: \"admin\" }, u);\n" +
      "if (!(r.matchedCount || r.nMatched)) r = db.users.updateOne({ username: \"admin\" }, u);\n" +
      "print((r.matchedCount || r.nMatched) ? \"ADMIN_UPDATED\" : \"ADMIN_NOT_FOUND\");\n";
    fs.writeFileSync(process.env.GENIEACS_ADMIN_JS, js, { mode: 0o600 });
  ' || die "gagal membuat hash password admin"

  if command -v mongosh >/dev/null 2>&1; then
    out="$(mongosh --quiet --file "$tmpjs" "mongodb://127.0.0.1:27017/genieacs" 2>/dev/null || true)"
  fi
  if [ -z "$out" ] && command -v mongo >/dev/null 2>&1; then
    out="$(mongo "mongodb://127.0.0.1:27017/genieacs" --quiet "$tmpjs" 2>/dev/null || true)"
  fi
  rm -f "$tmpjs"

  case "$out" in
    *ADMIN_UPDATED*) echo "  Password admin diganti (hash PBKDF2-SHA512, salt acak)" ;;
    *ADMIN_NOT_FOUND*) echo "  PERINGATAN: user admin belum ada (wizard UI belum dijalankan); password tidak diubah" ;;
    *) echo "  PERINGATAN: gagal set password otomatis; ganti lewat UI -> Admin -> Users" ;;
  esac

  # cache user ada di memori proses UI
  systemctl restart genieacs-ui >/dev/null 2>&1 || true
}

if [ -n "$ADMIN_PASS" ]; then
  say "Set password admin"
  set_admin_password "$ADMIN_PASS"
fi

health_check

if ss -tln 2>/dev/null | grep -qE '(0\.0\.0\.0|\[::\]|\*):27017\b'; then
  echo
  echo "PERINGATAN: MongoDB listen di semua interface tanpa autentikasi."
  echo "  Batasi dengan bindIp: 127.0.0.1 di /etc/mongod.conf lalu restart mongod."
fi
if [ -z "$OPEN_LAN" ] && ss -tln 2>/dev/null | grep -qE '(0\.0\.0\.0|\[::\]|\*):7557\b'; then
  echo
  echo "PERINGATAN: NBI (7557) terbuka ke jaringan dan tidak punya autentikasi."
  echo "  Gunakan --open-lan <CIDR> agar hanya LAN ONT yang bisa mengakses."
fi

echo
echo "SELESAI. Langkah berikut:"
echo "  1. Buka http://<host>:3000 (tunnel: ssh -L 13000:127.0.0.1:3000 root@<host>)"
echo "  2. Wizard pertama -> centang semua -> ABRACADABRA!"
echo "  3. Login admin (default admin/admin, atau password dari --admin-pass)"
echo "  4. GANTI password admin bila masih default (UI -> Admin -> Users)."
echo "  5. JWT secret acak di $ENV_FILE (chmod 600)."
echo "  6. Log install: $LOG"
