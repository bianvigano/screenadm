
# 📺 screenadm v3.0

**screenadm** adalah *session manager* berbasis POSIX shell untuk GNU Screen yang memungkinkan Anda mengelola aplikasi multi-window secara deklaratif hanya dengan satu file konfigurasi.

---

## 📌 Daftar Isi

* [Fitur](#-fitur-utama)
* [Instalasi](#-instalasi)
* [Penggunaan](#-cara-penggunaan)
* [Contoh Konfigurasi](#-contoh-konfigurasi)
* [Tips](#-tips)

---

## ✨ Fitur Utama

* **Declarative Apply**
  Terapkan konfigurasi (`TITLE`, `DIR`, `ENV`, `CMD`) secara otomatis dan *idempotent* (tidak membuat window duplikat).

* **Interactive TUI Menu**
  Dashboard interaktif dengan navigasi panah atau Vim keys (`h/j/k/l`).

* **Auto-Respawn**
  Window dapat otomatis restart jika proses berhenti (`WINn_RESPAWN="yes"`).

* **Healthcheck**
  Monitoring kesehatan aplikasi langsung dari dashboard.

* **Namespace Support**
  Isolasi sesi menggunakan prefix agar tidak bentrok.

* **Remote Management**
  Deploy dan kelola sesi ke server remote via SSH/SCP.

* **Zero Dependencies**
  Hanya membutuhkan `/bin/sh` dan `screen` (tanpa `grep`, `sed`, `awk` eksternal).

---

## 🚀 Instalasi

1. Unduh file `screenadm.sh`
2. Berikan izin eksekusi:

```bash
chmod +x screenadm.sh
```

3. (Opsional) Pindahkan ke PATH:

```bash
mv screenadm.sh /usr/local/bin/screenadm
```

---

## 🛠️ Cara Penggunaan

### 1. Membuat Template Konfigurasi

```bash
screenadm template fullstack > myapp.cfg
```

---

### 2. Menerapkan Konfigurasi

```bash
screenadm apply myapp.cfg
```

---

### 3. Membuka Dashboard (TUI)

```bash
screenadm menu
```

### 3. Perintah Dasar Terminal

| Perintah | Deskripsi |
| :--- | :--- |
| `./screenadm apply myapp.cfg` | Membangun/update sesi berdasarkan config. |
| `./screenadm menu` | Buka Dashboard Interaktif (TUI). |
| `./screenadm status` | Cek semua sesi yang aktif. |
| `./screenadm down web-stack` | Matikan sesi `web-stack` secara bersih. |
| `./screenadm up web-stack` | Hidupkan kembali sesi dari cache konfigurasi terakhir. |
| `./screenadm attach web-stack` | Masuk ke sesi dengan menu pilihan window. |



---

## 📝 Contoh Konfigurasi

File: `myapp.cfg`

```bash
SESSION="prod-app"
WIN_COUNT=2

# Window 1: API Server
WIN1_TITLE="api"
WIN1_DIR="/home/user/app"
WIN1_ENV="PORT=3000"
WIN1_CMD="node server.js"
WIN1_RESPAWN="yes"
WIN1_HEALTHCHECK='curl -s localhost:3000/health'

# Window 2: Log Monitor
WIN2_TITLE="logs"
WIN2_CMD="tail -f /var/log/app.log"
```

---

## 💡 Tips

* Gunakan `RESPAWN="yes"` untuk service penting agar tetap berjalan.
* Tambahkan `HEALTHCHECK` untuk monitoring otomatis.
* Gunakan namespace jika menjalankan banyak proyek sekaligus.
* Simpan file `.cfg` di repo project untuk versioning.
