# Caduceus

**Biarkan Claude Code menyerahkan pekerjaan coding rutin ke [Hermes Agent](https://github.com/NousResearch/hermes-agent), lalu memeriksa hasilnya.**

Claude menulis tugas dan memeriksa hasil. Hermes yang mengetik, memakai model yang jauh lebih murah, di worktree git miliknya sendiri, sehingga folder kerja Anda tidak tersentuh.

[English](README.md)

## Hasil

Diukur November 2026: Claude Opus 5.5 sebagai perencana dan pemeriksa, Hermes memakai DeepSeek V4.1 Flash.

| Yang diukur | Claude sendiri | Claude + Caduceus + Hermes |
|---|---|---|
| Tugas coding nyata dari aplikasi TypeScript produksi yang lolos pemeriksaan | 4 / 4 | **4 / 4** |
| Mutan yang tertangkap oleh tes yang ditulis (33 mutan tidak setara) | 32 / 33 | **33 / 33** |
| Pemakaian Claude per tugas (setara harga API) | ~$1,35 | **~$0,24 (hemat sekitar 82%)** |
| Biaya model di sisi Hermes, per tugas | | **~$0,06** |

Penghematan dari jembatannya sendiri:

| Optimasi | Sebelum | Sesudah |
|---|---|---|
| Token masuk per langkah Hermes, set alat coding | 18.272 | **8.823 (hemat 52%)** |
| Token untuk satu putaran revisi | 0,9 sampai 7 juta (melanjutkan sesi lama) | **~42.000 (sesi baru yang ringkas)** |

Untuk video, draf Remotion buatan Hermes sendiri mendapat skor **29 / 35** dalam penilaian buta, dibanding 31 / 35 untuk Claude sendiri.

Angka ini berasal dari sekumpulan kecil tugas di satu proyek. Hasil Anda akan berbeda tergantung kode, model, dan harga.

## Cara kerja

```
Claude Code ── menulis TASK.md ──> caduceus.ps1 ── menjalankan ──> hermes chat (di worktree git)
     ^                                                                    │
     └──── membaca commit, diff, hasil tes, RESULT.md <───────────────────┘
```

1. Claude menulis file tugas singkat: tujuan, konteks, file yang boleh diubah, dan perintah cek yang membuktikan tugas selesai.
2. Caduceus mengecek model, membuat worktree di cabang `hermes/<nama>`, lalu menjalankan Hermes hanya dengan alat yang dibutuhkan.
3. Selama Hermes bekerja, Caduceus menjaga batas waktu, memantau RAM, dan mencatat setiap langkah.
4. Saat Hermes berhenti, Caduceus meng-commit perubahan yang tertinggal, menjalankan perintah tes, dan mencetak laporan.
5. Claude memeriksa diff. Kalau ada yang salah, revisi dikirim sebagai sesi baru yang ringkas, bukan mengulang seluruh riwayat.

## Kebutuhan

- Windows 10 atau 11 dengan PowerShell 7 (`pwsh`)
- git
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) yang sudah tersambung ke model lewat endpoint yang kompatibel dengan OpenAI
- [Claude Code](https://claude.com/claude-code), kalau ingin Claude yang mengendalikan (skripnya juga bisa dijalankan sendiri)

## Pasang

Clone sebagai skill Claude Code:

```powershell
git clone https://github.com/uuuraa-elv/caduceus "$env:USERPROFILE\.claude\skills\caduceus"
```

Opsional: salin `caduceus.config.example.json` menjadi `caduceus.config.json` di folder yang sama, lalu isi daftar model sesuai urutan cadangan.

## Pakai

Dari Claude Code, cukup minta: *"Kirim ke Hermes: tambahkan validasi input di handler pendaftaran, tes di tests/signup.test.ts harus lolos."* Skill ini memberi tahu Claude cara menulis tugas, menjalankannya, dan memeriksanya.

Manual:

```powershell
# tugas baru
pwsh -File caduceus.ps1 -Repo C:\code\app -Task C:\tmp\TASK.md -Name validasi-daftar -Test "npm test"

# revisi sebagai sesi baru yang ringkas (murah)
pwsh -File caduceus.ps1 -Repo C:\code\app -Name validasi-daftar -Revise "Email kosong masih lolos, tolak."
```

Daftar lengkap parameter dan isi config ada di [README bahasa Inggris](README.md#use).

## Kapan sebaiknya dikerjakan Claude saja

- Desain UI, debug lintas banyak file, atau repo tanpa tes: menulis tugasnya sama beratnya dengan mengerjakannya.
- Video HyperFrames: dalam uji kami hasilnya paling rendah lewat Hermes.
- Pekerjaan mendesak: Hermes dengan model murah butuh sekitar 2,5 kali lebih lama per tugas coding.

## Tes

```powershell
pwsh -File tests/run-tests.ps1
```

Berjalan offline dengan `hermes` tiruan, jadi tidak ada model yang dipanggil.

## Lisensi

MIT. Copyright (c) 2026 Fuad Nurhadi ([fuadnurhadi.my.id](https://fuadnurhadi.my.id)).
