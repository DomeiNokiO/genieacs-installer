# GenieACS Auto Installer

Installer otomatis satu file (zero-interaction) untuk menginstal [GenieACS](https://genieacs.com/) ori (Node.js + MongoDB) di kontainer (CT) Ubuntu atau Debian (termasuk LXC Proxmox).

## 🌟 Fitur Unggulan

- **Deteksi OS Otomatis:** Mendukung Ubuntu 20.04/22.04/24.04 dan Debian 11/12/13.
- **Pemilihan MongoDB yang Valid:** Versi MongoDB dipilih berdasarkan set instruksi CPU **dan** ketersediaan repo resmi untuk distro Anda:
  - CPU dengan **AVX** → MongoDB **7.0** (Ubuntu 24.04 otomatis memakai **8.0**, karena MongoDB tidak merilis repo 7.0 untuk `noble`).
  - CPU **TANPA AVX** (mis. Celeron J4105 lama atau CPU LXC tanpa passthrough) → MongoDB **4.4** + `libssl1.1` (MongoDB 5.0 ke atas akan crash tanpa AVX).
  - URL repo `Release` diverifikasi lebih dulu; kalau tidak ada, script mencoba kandidat berikutnya dan berhenti dengan pesan jelas — bukan gagal di tengah `apt-get`.
- **Node.js LTS:** Menginstal Node.js 22 via NodeSource jika belum ada; Node < 18 otomatis di-upgrade (Node 18+ dibiarkan agar tidak mengganggu aplikasi lain di CT).
- **Isolasi Service & Systemd:** Membuat user OS `genieacs`, JWT secret acak (128 byte) di `genieacs.env` ber-izin `600`, dan 4 layanan systemd (`genieacs-cwmp`, `genieacs-nbi`, `genieacs-fs`, `genieacs-ui`).
- **Firewall Opsional (non-destruktif):** `--open-lan` mengaktifkan UFW dengan *default deny incoming* tanpa **menghapus** rules yang sudah ada. Port SSH dideteksi otomatis dari `sshd -T`.
- **Password Admin Aman:** `--admin-pass` menyimpan password sebagai hash **PBKDF2-SHA512 + salt acak**, sama seperti yang dipakai GenieACS (bukan plaintext).
- **Restore Parameter:** `--with-params` mengunduh dan merestore parameter custom `paimo54`. DB di-backup lebih dulu, lalu koleksi `users` dikembalikan dari backup agar login admin tidak rusak.

## 🚀 Instalasi Cepat (Satu Baris)

Buka terminal CT (sebagai root) dan jalankan:

```bash
curl -fsSL https://raw.githubusercontent.com/DomeiNokiO/genieacs-installer/master/install.sh -o install.sh && chmod +x install.sh && sudo ./install.sh
```

Instalasi instan tanpa menyimpan file, opsi lewat variabel lingkungan:

```bash
curl -fsSL https://raw.githubusercontent.com/DomeiNokiO/genieacs-installer/master/install.sh | sudo OPEN_LAN="10.19.12.0/24" bash
```

> Branch default repo ini adalah **`master`**. Jika Anda memakai fork, sesuaikan URL-nya.

## ⚙️ Opsi CLI Lengkap

```bash
./install.sh [OPSI]
```

| Opsi | Fungsi |
|---|---|
| `--version <VERSI>` | Versi NPM GenieACS (default: `latest`, disarankan `1.2.16`). Jika GenieACS sudah terpasang dengan versi lain, akan di-upgrade. |
| `--mongo <VERSI>` | `auto` (default), `4.4`, `7.0`, `8.0`. `auto` memilih berdasarkan AVX + ketersediaan repo. |
| `--mongo-suite <CODENAME>` | Paksa codename suite repo MongoDB (mis. `bookworm`). Untuk kasus khusus / distro turunan. |
| `--open-lan <CIDR>` | Aktifkan UFW: tolak semua koneksi masuk, buka port SSH + port ACS (7547, 7557, 7567, 3000) **hanya** dari CIDR tersebut (mis. `10.19.12.0/24`). |
| `--ssh-port <PORT>` | Port SSH yang tetap dibuka saat UFW aktif. Default `auto` (dibaca dari `sshd -T`, fallback 22). |
| `--with-params` | Restore set parameter custom `paimo54`. Backup DB dibuat dulu (termasuk backup khusus `users`) lalu user dikembalikan setelah restore. |
| `--admin-pass <PASS>` | Set password `admin` web UI (disimpan sebagai hash). Lebih aman lewat env: `sudo ADMIN_PASS='...' ./install.sh`. |
| `--check-only` | Health check semua komponen tanpa mengubah instalasi (butuh root). |
| `--help` | Tampilkan bantuan. |

### Contoh Pemakaian Tingkat Lanjut

Instal versi 1.2.16, restore parameter custom, batasi ke subnet `192.168.100.0/24`, dan set password admin tanpa menaruhnya di history shell:

```bash
sudo ADMIN_PASS='RahasiaSekali123' ./install.sh \
  --version 1.2.16 --with-params --open-lan 192.168.100.0/24
```

## 🛠 Peta Port dan Layanan

| Layanan | Port | Keterangan |
|---|---|---|
| `genieacs-cwmp` | **7547** | Harus bisa dihubungi semua CPE/ONT. |
| `genieacs-nbi` | **7557** | REST API internal, dipanggil oleh web UI dari browser. **Tidak punya autentikasi** — batasi dengan `--open-lan`. |
| `genieacs-fs` | **7567** | Manajemen file/firmware. Versi lama memakai 7546. |
| `genieacs-ui` | **3000** | Web dashboard. |

## 🔧 Panduan Pasca Instalasi

1. **Akses Web UI**
   Buka `http://<IP_CT>:3000`. Jika CT di belakang NAT/firewall ketat, pakai SSH tunnel:
   ```bash
   ssh -L 13000:127.0.0.1:3000 root@<IP_PUBLIC> -p <PORT_SSH_PUBLIC>
   ```
   Lalu buka `http://127.0.0.1:13000`.

2. **Inisialisasi Pertama Kali (Wizard)**
   Saat pertama buka UI, centang **semua opsi** lalu tekan **ABRACADABRA!**.

3. **Login dan Amankan Akun**
   - Username: `admin`
   - Password: `admin` (atau nilai dari `--admin-pass`)
   Segera ganti lewat menu kanan atas → **Admin** → **Users**.

4. **Keamanan JWT**
   JWT secret digenerate acak (128 byte hex) di `/opt/genieacs/genieacs.env`, hanya bisa dibaca root dan user `genieacs` (`chmod 600`).

## 🩺 Troubleshooting

- **`mongod` langsung mati di CT lama** → CPU tanpa AVX. Jalankan ulang dengan `--mongo 4.4` (script `auto` sudah mendeteksi ini).
- **`apt-get update` gagal setelah repo MongoDB ditambahkan** → script otomatis menghapus file list yang bermasalah dan berhenti, jadi `apt` tidak rusak. Cek pesan `MongoDB ... untuk <distro>/<suite> tidak tersedia` lalu pilih `--mongo`/`--mongo-suite` yang sesuai.
- **Login admin gagal setelah `--with-params`** → user seharusnya sudah dikembalikan otomatis. Jika tidak, restore manual: `mongorestore --db genieacs --collection users --drop /var/backups/genieacs/users-only/genieacs/users.bson`. Backup penuh ada di `/var/backups/genieacs/`.
- **Status cepat:** `sudo ./install.sh --check-only` (layanan, port listen, HTTP UI/NBI, ping MongoDB).

## ⚠️ Catatan Keamanan

- Tanpa `--open-lan`, port **7557 (NBI)** dan **3000 (UI)** terbuka ke jaringan. NBI tidak punya autentikasi dan bisa mengubah semua perangkat, jadi untuk produksi selalu pakai `--open-lan <CIDR>`.
- `--open-lan` tidak lagi menjalankan `ufw --force reset`, sehingga rules firewall yang sudah ada tidak hilang.
- MongoDB dari paket resmi listen di `127.0.0.1`; script memperingatkan jika suatu saat bind-nya melebar ke semua interface.
- `--admin-pass` di CLI terlihat di `ps` dan history shell. Gunakan variabel lingkungan seperti contoh di atas.
