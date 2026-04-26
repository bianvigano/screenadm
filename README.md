# screenadm v3.0

[cite_start]**screenadm** adalah manager berbasis POSIX shell script untuk GNU Screen yang dirancang untuk otomatisasi sesi dan window secara deklaratif[cite: 1]. [cite_start]Alat ini memungkinkan Anda mengelola aplikasi multi-window yang kompleks hanya dengan satu file konfigurasi[cite: 1, 9].

## ✨ Fitur Utama

* [cite_start]**Declarative Apply**: Terapkan konfigurasi (TITLE, DIR, ENV, CMD) secara otomatis dan bersifat *idempotent* (tidak membuat window duplikat)[cite: 1, 11].
* [cite_start]**Interactive TUI Menu**: Dashboard interaktif menggunakan navigasi panah atau Vim keys (`j/k/h/l`) untuk manajemen sesi yang cepat[cite: 1, 102].
* [cite_start]**Auto-Respawn**: Fitur `WINn_RESPAWN="yes"` untuk memastikan window otomatis berjalan kembali jika proses di dalamnya berhenti[cite: 1].
* [cite_start]**Healthcheck**: Integrasi pengecekan kesehatan aplikasi secara langsung di dalam dashboard[cite: 1, 36].
* [cite_start]**Namespace Support**: Mengisolasi sesi menggunakan prefix sehingga tidak bentrok dengan sesi screen lainnya[cite: 1, 12].
* [cite_start]**Remote Management**: Mendukung penerapan konfigurasi ke server remote melalui SSH/SCP[cite: 1].
* **Zero Dependencies**: Hanya membutuhkan `/bin/sh` standar dan `screen`. [cite_start]Tidak memerlukan `grep`, `sed`, atau `awk` eksternal untuk fungsi intinya[cite: 1, 2].

## 🚀 Instalasi

1.  Unduh file `screenadm.sh`.
2.  Berikan izin eksekusi:
    ```bash
    chmod +x screenadm.sh
    ```
3.  Pindahkan ke folder PATH Anda (opsional):
    ```bash
    mv screenadm.sh /usr/local/bin/screenadm
    ```

## 🛠️ Cara Penggunaan

### 1. Membuat Template Konfigurasi
Anda bisa memulai dengan mencetak template bawaan:
```bash
./screenadm template fullstack > myapp.cfg
```

### 2. Menerapkan Konfigurasi
Jalankan sesi berdasarkan file `.cfg` yang telah dibuat:
```bash
./screenadm apply myapp.cfg
```

### 3. Menggunakan Dashboard (TUI)
Masuk ke menu interaktif untuk mengontrol semua sesi:
```bash
./screenadm menu
```

## 📝 Contoh Konfigurasi (`myapp.cfg`)

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
[cite_start]
http://googleusercontent.com/immersive_entry_chip/0
