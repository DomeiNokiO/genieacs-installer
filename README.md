# GenieACS Auto Installer

Installer otomatis satu file (zero-interaction) untuk menginstal [GenieACS](https://genieacs.com/) ori (Node.js + MongoDB) di kontainer (CT) Ubuntu atau Debian (termasuk LXC Proxmox).

## 🌟 Fitur Unggulan

- **Deteksi OS Otomatis:** Mendukung Ubuntu 20.04/22.04/24.04 dan Debian 11/12; repositori disesuaikan otomatis.
- **Deteksi AVX (Smart MongoDB):** 
  - Jika host/CT memiliki set instruksi AVX, menginstal **MongoDB 7.0**.
  - Jika host/CT **TANPA AVX** (seperti prosesor Celeron J4105 lama atau seting CPU LXC tanpa passthrough), otomatis fallback ke **MongoDB 4.4** beserta `libssl1.1` (MongoDB 5.0 ke atas akan crash tanpa AVX).
- **Node.js LTS:** Menginstal Node.js 22 terbaru via NodeSource.
- **Isolasi Service & Systemd:** Membuat user OS `genieacs`, menempatkan JWT secret secara acak ke `.env` ber-izin `600`, dan membuat 4 layanan systemd (`genieacs-cwmp`, `genieacs-nbi`, `genieacs-fs`, `genieacs-ui`).
- **Firewall Opsional:** Mendukung opsi pembatasan akses hanya untuk subnet LAN ONT dengan UFW otomatis.
- **Restore Parameter:** Opsi `--with-params` untuk mengunduh dan merestore koleksi parameter custom pihak ketiga secara otomatis ke MongoDB.

## 🚀 Instalasi Cepat (Satu Baris)

Buka terminal CT (sebagai root) dan jalankan:

```bash
curl -fsSL https://raw.githubusercontent.com/DomeiNokiO/genieacs-installer/main/install.sh -o install.sh && chmod +x install.sh && sudo ./install.sh
```

Untuk instalasi instan tanpa menyimpan file, sertakan opsi melalui variabel lingkungan (environment variables):

```bash
curl -fsSL https://raw.githubusercontent.com/DomeiNokiO/genieacs-installer/main/install.sh | sudo OPEN_LAN="10.19.12.0/24" bash
```

## ⚙️ Opsi CLI Lengkap

Jalankan script yang telah didownload dengan flag opsional berikut:

```bash
./install.sh [OPSI]
```

| Opsi | Fungsi |
|---|---|
| `--version <VERSI>` | Versi spesifik NPM GenieACS (default: `latest`, disarankan `1.2.16`) |
| `--mongo <VERSI>` | Paksa versi MongoDB: `auto`, `4.4`, `7.0` (default: `auto` dari deteksi AVX) |
| `--open-lan <CIDR>` | Aktifkan UFW: Blokir semua koneksi luar *kecuali* port SSH (22) dan port ACS (7547, 7557, 7567, 3000) **HANYA** dari rentang IP LAN ONT (mis. `10.19.12.0/24`) |
| `--with-params` | Unduh dan restore set parameter custom `paimo54`. Database di-backup lebih dulu. Sangat aman. |
| `--admin-pass <PASS>`| Langsung ubah password `admin` web UI dari bawaannya ("admin"). |
| `--check-only` | Lakukan health check semua komponen tanpa mengubah instalasi. |
| `--help` | Tampilkan bantuan. |

### Contoh Pemakaian Tingkat Lanjut

Menginstal versi 1.2.16, merestore parameter custom, dan hanya mengizinkan subnet `192.168.100.0/24`:
```bash
./install.sh --version 1.2.16 --with-params --open-lan 192.168.100.0/24
```

## 🛠 Peta Port dan Layanan
Setelah instalasi selesai, layanan ini tersedia di CT Anda:
- `genieacs-cwmp` di port **7547** (layanan wajib yang harus bisa dihubungi oleh semua CPE/ONT).
- `genieacs-nbi` di port **7557** (REST API internal, digunakan oleh web UI).
- `genieacs-fs` di port **7567** (Layanan manajemen file firmware. Catatan: Versi lama menggunakan 7546).
- `genieacs-ui` di port **3000** (Web dashboard GUI).

## 🔧 Panduan Penyelesaian Pasca Instalasi

1. **Akses Web UI** 
   Buka browser ke `http://<IP_CT>:3000`. Jika CT ada di belakang NAT/Firewall ketat, gunakan SSH tunnel:
   ```bash
   ssh -L 13000:127.0.0.1:3000 root@<IP_PUBLIC> -p <PORT_SSH_PUBLIC>
   ```
   Lalu buka browser lokal ke `http://127.0.0.1:13000`.

2. **Inisialisasi Pertama Kali (Wizard)**
   GenieACS memerlukan konfigurasi letak menu. Saat pertama buka UI, Anda disuguhi *Wizard*. Centang **semua opsi** dan tekan tombol **ABRACADABRA!**.

3. **Login dan Amankan Akun**
   Masuk menggunakan kredensial default:
   - Username: `admin`
   - Password: `admin`
   
   👉 **Penting:** Segera ganti password ini melalui menu pojok kanan atas -> **Admin** -> **Users**.

4. **Kemanan JWT**
   Secret kunci (JWT Secret) untuk sesi login telah digenerate secara acak dan aman (128 bytes hex) di `/opt/genieacs/genieacs.env`. File ini diamankan dan hanya dapat dibaca oleh root dan user `genieacs`.
