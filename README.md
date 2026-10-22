# GenieACS Installer

Script bash untuk memasang GenieACS asli (Node.js + MongoDB) di container Ubuntu atau Debian, termasuk LXC Proxmox. Sekali jalan, tanpa pertanyaan interaktif.

## Yang dilakukan script

- Mendeteksi distro dan versi, lalu memakai repo MongoDB yang memang tersedia untuk distro itu.
- CPU dengan AVX dipasangi MongoDB 7.0. Khusus Ubuntu 24.04 dipakai MongoDB 8.0 karena MongoDB tidak merilis repo 7.0 untuk `noble`.
- CPU tanpa AVX (mis. Celeron J4105, atau container LXC yang tidak meneruskan flag CPU) dipasangi MongoDB 4.4 dan `libssl1.1`, karena MongoDB 5.0 ke atas gagal start tanpa AVX.
- Memasang Node.js 22 dari NodeSource kalau belum ada. Node versi di bawah 18 akan diganti; versi 18 ke atas dibiarkan supaya aplikasi lain di CT tidak ikut rusak.
- Membuat user sistem `genieacs`, JWT secret acak di `/opt/genieacs/genieacs.env` dengan permission `600`, dan empat unit systemd: `genieacs-cwmp`, `genieacs-nbi`, `genieacs-fs`, `genieacs-ui`.
- Tiga hal opsional: batasi akses dengan UFW, restore parameter `paimo54`, dan ganti password admin.

## Syarat

- Ubuntu 20.04, 22.04, 24.04, atau Debian 11, 12, 13
- Akses root
- Koneksi ke repo apt, NodeSource, repo MongoDB, dan npm

## Instalasi

```bash
curl -fsSL https://raw.githubusercontent.com/DomeiNokiO/genieacs-installer/master/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

Kalau tidak mau menyimpan file:

```bash
curl -fsSL https://raw.githubusercontent.com/DomeiNokiO/genieacs-installer/master/install.sh \
  | sudo OPEN_LAN=10.19.12.0/24 bash
```

Branch repo ini `master`. Kalau memakai fork, ganti URL-nya.

## Opsi

Jalankan `./install.sh --help` untuk daftar lengkap. Yang sering dipakai:

| Opsi | Keterangan |
|---|---|
| `--version <versi>` | Versi npm GenieACS. Default `latest`, yang stabil `1.2.16`. |
| `--mongo <versi>` | `auto` (default), `4.4`, `7.0`, atau `8.0`. |
| `--mongo-suite <codename>` | Paksa codename repo MongoDB, untuk kasus yang tidak terdeteksi otomatis. |
| `--open-lan <CIDR>` | Aktifkan UFW. Port ACS hanya dibuka untuk CIDR ini, port SSH tetap terbuka. |
| `--ssh-port <port>` | Port SSH yang tetap dibuka saat UFW aktif. Default dibaca dari `sshd -T`, fallback 22. |
| `--with-params` | Restore parameter `paimo54`. Database di-backup dulu. |
| `--admin-pass <pass>` | Set password `admin` (disimpan sebagai hash, bukan plaintext). |
| `--check-only` | Cek status layanan, port, HTTP, dan MongoDB tanpa mengubah apa pun. |

Contoh:

```bash
sudo ADMIN_PASS='rahasia' ./install.sh --version 1.2.16 --with-params --open-lan 192.168.100.0/24
```

Kalau `--admin-pass` ditulis di command line, nilainya ikut tersimpan di history shell dan terlihat di `ps`. Lebih baik lewat environment variable seperti contoh di atas.

## Port

| Layanan | Port |
|---|---|
| genieacs-cwmp | 7547 |
| genieacs-nbi | 7557 |
| genieacs-fs | 7567 |
| genieacs-ui | 3000 |

MongoDB hanya listen di `127.0.0.1`.

## Setelah instalasi

1. Buka `http://<ip-ct>:3000`. Kalau CT di belakang NAT, pakai tunnel:
   ```bash
   ssh -L 13000:127.0.0.1:3000 root@<ip-publik> -p <port-ssh>
   ```
   lalu buka `http://127.0.0.1:13000`.
2. Saat pertama dibuka, UI menampilkan wizard. Centang semua opsi dan tekan ABRACADABRA.
3. Login dengan `admin` / `admin`, atau password yang diberikan lewat `--admin-pass`.
4. Ganti password lewat menu Admin > Users.

JWT secret ada di `/opt/genieacs/genieacs.env`, hanya bisa dibaca root dan user `genieacs`.

## Keamanan

- NBI di port 7557 tidak punya autentikasi dan bisa mengubah semua perangkat. Untuk produksi, pakai `--open-lan` supaya port ini hanya bisa diakses dari jaringan ONT.
- Tanpa `--open-lan`, UI dan NBI terbuka ke semua interface.
- `--open-lan` tidak menghapus rules firewall yang sudah ada.

## Troubleshooting

`mongod` mati beberapa detik setelah start berarti CPU tidak punya AVX. Jalankan ulang dengan `--mongo 4.4`.

Kalau `apt-get update` gagal setelah repo MongoDB ditambahkan, script menghapus file list yang bermasalah dan berhenti, jadi apt tidak tertinggal dalam kondisi rusak. Pesan errornya menyebut distro/suite yang dicoba.

Login admin bermasalah setelah `--with-params`, restore user secara manual:

```bash
mongorestore --db genieacs --collection users --drop \
  /var/backups/genieacs/users-only/genieacs/users.bson
```

Backup penuh sebelum restore ada di `/var/backups/genieacs/`.

Cek status kapan saja:

```bash
sudo ./install.sh --check-only
```

## Kontributor

- AWG-NET
