# Ringkasan Project Internet Download Manager

## Tujuan

Aplikasi desktop pengelola unduhan untuk macOS dan Windows, dibuat dengan Flutter. Aplikasi menyediakan antrean unduhan, kontrol transfer, dan integrasi Google Chrome. Untuk media streaming berbasis HLS atau DASH, aplikasi menggunakan FFmpeg.

## Arsitektur singkat

- **Aplikasi desktop Flutter (`lib/`)** — UI bergaya download manager, antrean persisten, status/progress, serta aksi pause, resume, cancel, retry, dan pengaturan unduhan.
- **Mesin unduhan (`lib/services/`)** — HTTP/HTTPS, resume dengan Range, unduhan paralel tersegmentasi untuk server yang mendukungnya, dan alur FFmpeg untuk manifest stream.
- **Integrasi Chrome (`browser/chrome/`)** — extension unpacked menyediakan menu konteks “Download with IDM” dan mendeteksi URL langsung serta manifest HLS/DASH dari permintaan jaringan.
- **Native messaging host (`browser/native_host/`)** — menerima pesan Chrome lalu meneruskannya ke bridge lokal aplikasi.
- **Bridge lokal** — memvalidasi autentikasi, URL, dan header yang diterima sebelum membuat task unduhan.
- **Integrasi platform (`macos/`, `windows/`)** — jendela dapat disembunyikan ke menu bar/tray agar proses tetap hidup; tersedia aksi untuk membuka kembali atau keluar.

Alur Chrome: **menu konteks / deteksi stream → extension → native messaging host → bridge lokal terautentikasi → antrean Flutter → HTTP engine atau FFmpeg**.

## Yang sudah dikerjakan

- Inisialisasi aplikasi Flutter desktop untuk macOS dan Windows, termasuk revamp UI agar terasa seperti aplikasi download manager.
- Antrean unduhan persisten dan aksi dasar untuk mengelola transfer.
- Download HTTP/HTTPS dengan progress, pause/resume/cancel/retry, resume parsial, serta segmentasi paralel bila server mendukung HTTP Range.
- Pemeriksaan validator ETag atau Last-Modified dan penggunaan `If-Range` untuk menghindari penggabungan bagian dari versi file yang berbeda.
- Ekstensi Google Chrome unpacked dengan menu konteks untuk link, video, audio, dan gambar serta native messaging host.
- Deteksi manifest HLS (`.m3u8`/MIME) dan DASH (`.mpd`/MIME), pemetaan konteks media `blob:` ke manifest yang tertangkap, dan penerusan header sesi yang relevan.
- Unduhan stream melalui FFmpeg ke MKV, termasuk progress, penanganan nama file bentrok, dan kontrol pembatalan/jeda.
- Aplikasi dapat tetap berjalan di background saat jendela ditutup, dengan menu bar macOS atau system tray Windows.
- Pengujian unit untuk model task, bridge browser, antrean, stream engine, dan pengujian Node untuk service worker Chrome.

## Batasan dan status verifikasi

- Ekstensi Chrome masih perlu dimuat manual sebagai **unpacked extension** dan native messaging host harus didaftarkan pada tiap komputer.
- Stream memerlukan FFmpeg yang tersedia di `PATH` (atau lokasi yang dikonfigurasi) dengan demuxer HLS dan DASH yang sesuai. DRM-protected streams tidak didukung.
- Header autentikasi stream bersifat sementara dan tidak disimpan ke file antrean. Jika aplikasi dimulai ulang, task yang membutuhkan header sesi mungkin perlu ditambahkan ulang dari browser.
- Pengujian Node untuk service worker lulus dan smoke test HLS lokal berhasil. FFmpeg yang tersedia saat verifikasi tidak menyediakan DASH input demuxer, jadi DASH belum terverifikasi end-to-end di lingkungan tersebut.
- `flutter test` belum berhasil dijalankan di lingkungan pengembangan terakhir karena Flutter SDK mencoba menulis cache/lock di luar workspace yang diizinkan. Jalankan ulang pada setup Flutter yang dapat menulis cache.
- Belum ada verifikasi end-to-end terpublikasi untuk semua situs, format stream, dan kedua OS. Hasil bisa bergantung pada situs, sesi login, format media, build FFmpeg, dan dukungan server.

## Next step yang disarankan

1. **Jalankan seluruh test suite Flutter** pada mesin dengan Flutter SDK yang berfungsi; catat dan perbaiki kegagalan sebelum rilis.
2. **Uji alur Chrome end-to-end** di macOS dan Windows: URL file langsung, HLS, DASH, video `blob:`, situs dengan cookie/header, tab tanpa stream, serta aplikasi tertutup atau bridge tidak tersedia.
3. **Pastikan dukungan FFmpeg di target**: uji build FFmpeg yang memiliki demuxer HLS dan DASH; tampilkan pesan instalasi yang jelas saat executable atau demuxer tidak tersedia.
4. **Tuntaskan pengalaman background dan lifecycle** di dua OS: ikon tray/menu bar, buka kembali, keluar, dan perilaku unduhan aktif saat jendela ditutup.
5. **Siapkan distribusi**: paket installer macOS dan Windows, signing/notarization yang diperlukan, registrasi native host yang mudah, serta petunjuk pemasangan extension.
6. **Perkuat rilis**: CI untuk analisis dan test, uji build pada macOS/Windows, lalu dokumentasikan versi yang benar-benar telah diverifikasi.

## Cara menjalankan

```sh
flutter pub get
flutter run -d macos
```

Di Windows, gunakan `flutter run -d windows`. Panduan setup Chrome dan native messaging host ada di [README.md](README.md).
