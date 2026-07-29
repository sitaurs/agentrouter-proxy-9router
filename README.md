# AgentRouter compatibility proxy for 9Router

Proxy lokal ringan agar endpoint OpenAI-compatible milik AgentRouter dapat
dipakai sebagai provider di 9Router, termasuk untuk respons streaming dan
pencatatan token.

> Proyek komunitas tidak resmi. Repository ini tidak berafiliasi dengan
> AgentRouter, 9Router, Roo Code, atau Anthropic.

## Masalah yang diselesaikan

Menghubungkan 9Router langsung ke AgentRouter dapat menghasilkan beberapa
masalah:

- `401 Unauthorized` walaupun key tampak benar;
- test connection 9Router gagal atau tidak konsisten;
- streaming SSE terlihat berhenti atau terpotong;
- event billing tercampur dengan event chat;
- statistik input/output token tercatat `0/0`;
- field JSON `null` ditolak oleh upstream.

Proxy ini ditempatkan di antara keduanya:

```text
9Router
   │  OpenAI-compatible HTTP/SSE
   ▼
http://127.0.0.1:4182/v1
   │  inject API key + adapt request/response
   ▼
https://agentrouter.org/v1
```

## Fitur

- Menyisipkan API key AgentRouter dari file lokal atau environment variable.
- Menambahkan header kompatibilitas yang dibutuhkan endpoint AgentRouter.
- Menghapus field JSON bernilai `null`.
- Menambahkan `stream_options.include_usage=true` pada request streaming.
- Meneruskan SSE per event tanpa menunggu buffer besar terisi.
- Menghapus event `billing.summary` dari stream chat.
- Menormalisasi usage non-stream dan streaming agar token terbaca 9Router.
- Menyesuaikan health probe bawaan 9Router untuk `claude-opus-5`.
- Retry otomatis maksimal tiga kali untuk `502`, `503`, dan `504`.
- Hanya memakai Python standard library; tidak perlu `pip install`.
- Default aman: hanya listen di `127.0.0.1`.

## Persyaratan

- Python 3.11 atau lebih baru.
- API key AgentRouter yang masih aktif.
- 9Router yang berjalan di komputer yang sama, atau dapat mengakses komputer
  tempat proxy berjalan.
- Windows PowerShell untuk skrip start/stop otomatis. Linux dan macOS dapat
  menjalankan file Python secara langsung.

## Instalasi cepat di Windows

### Cara termudah

Setelah clone, klik dua kali:

```text
install.cmd
```

Installer akan:

1. memeriksa Python 3.11+;
2. meminta API key dalam input tersembunyi;
3. menjalankan seluruh unit test;
4. menyalakan dan memverifikasi proxy;
5. memasang watchdog saat login Windows;
6. menampilkan nilai yang perlu dimasukkan ke 9Router.

Watchdog memeriksa proxy setiap 30 detik. Jika proses mati, watchdog
menyalakannya kembali. Ia tidak me-restart proses yang sehat.

### 1. Clone repository

```powershell
git clone https://github.com/sitaurs/agentrouter-proxy-9router.git
cd agentrouter-proxy-9router
```

### 2. Jalankan installer

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Langkah manual di bawah tersedia jika tidak ingin memakai installer.

### 3. Simpan API key secara manual

Salin file contoh:

```powershell
Copy-Item .\api.example.txt .\api.txt
notepad .\api.txt
```

Ganti seluruh isinya dengan API key AgentRouter. Jangan menambahkan key tersebut
ke source code. File `api.txt` sudah diabaikan Git.

Sebagai alternatif, key dapat disediakan hanya untuk terminal aktif:

```powershell
$env:AGENTROUTER_API_KEY = "YOUR_AGENTROUTER_API_KEY"
```

Environment variable memiliki prioritas lebih tinggi daripada `api.txt`.

### 4. Jalankan proxy secara manual

```powershell
.\start-agentrouter-proxy.ps1
```

Jika berhasil:

```text
AgentRouter proxy started (...) on http://127.0.0.1:4182/health.
```

Periksa health endpoint:

```powershell
Invoke-RestMethod http://127.0.0.1:4182/health
```

Respons yang diharapkan:

```json
{"ok": true}
```

### 5. Tambahkan provider di 9Router

Buka dashboard 9Router, lalu buat provider **OpenAI Compatible** dengan nilai:

| Field | Nilai |
|---|---|
| Name | `AgentRouter Local` |
| Prefix | `ar` |
| API Type | `Chat Completions` |
| Base URL | `http://127.0.0.1:4182/v1` |
| API Key (for Check) | `local-proxy` |
| Model ID untuk test | `claude-opus-5` |

Nilai `local-proxy` hanya placeholder agar form 9Router menerima konfigurasi.
Proxy tidak meneruskannya; proxy memakai key dari `api.txt` atau
`AGENTROUTER_API_KEY`.

Setelah check berhasil, gunakan **Import from `/models`**. Jika perlu, model
dapat ditambahkan manual sesuai ID yang muncul dari endpoint AgentRouter.

Contoh pemanggilan melalui 9Router:

```powershell
$headers = @{
  Authorization = "Bearer YOUR_9ROUTER_KEY"
  "Content-Type" = "application/json"
}

$body = @{
  model = "ar/claude-opus-5"
  stream = $false
  messages = @(
    @{ role = "user"; content = "Reply exactly OK" }
  )
} | ConvertTo-Json -Depth 10

Invoke-RestMethod `
  -Uri "http://127.0.0.1:20128/v1/chat/completions" `
  -Method Post `
  -Headers $headers `
  -Body $body
```

Ganti `YOUR_9ROUTER_KEY` dengan key 9Router, bukan key AgentRouter.

### 6. Hentikan atau hapus pemasangan

```powershell
.\stop-agentrouter-proxy.ps1
```

Untuk menghapus autostart, menghentikan proxy, dan menghapus key lokal:

```powershell
.\uninstall.ps1
```

Gunakan `.\uninstall.ps1 -KeepApiKey` jika key ingin dipertahankan.

Log runtime tersedia secara lokal di:

- `agentrouter-proxy.log`
- `agentrouter-proxy-error.log`

Kedua file tersebut diabaikan Git.

## Menjalankan secara manual

Windows, Linux, atau macOS:

```bash
python agentrouter-proxy.py \
  --host 127.0.0.1 \
  --port 4182 \
  --upstream https://agentrouter.org \
  --key-file ./api.txt
```

Di Linux/macOS, instalasi terpandu tersedia:

```bash
chmod +x install.sh
./install.sh
```

Pilihan command line:

```text
--host       Alamat listen. Default: 127.0.0.1
--port       Port listen. Default: 4182
--upstream   URL AgentRouter. Harus HTTPS.
--key-file   File yang berisi API key. Default: ./api.txt
```

## Jika 9Router berjalan di Docker

`127.0.0.1` di dalam container adalah container itu sendiri, bukan komputer
host. Jalankan proxy agar dapat dijangkau Docker:

```powershell
python .\agentrouter-proxy.py --host 0.0.0.0 --port 4182
```

Lalu gunakan Base URL berikut di 9Router:

```text
http://host.docker.internal:4182/v1
```

Pada Linux Docker, tambahkan host gateway jika belum tersedia:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

> **Peringatan keamanan:** proxy tidak memiliki autentikasi inbound. Saat
> memakai `0.0.0.0`, batasi port `4182` dengan firewall agar tidak dapat
> diakses dari internet atau perangkat yang tidak dipercaya.

## Pengujian

Unit test tidak memanggil AgentRouter dan tidak membutuhkan API key:

```powershell
python -m unittest discover -s tests -v
```

Validasi syntax:

```powershell
python -m py_compile .\agentrouter-proxy.py
```

## Troubleshooting

### `401 Unauthorized`

1. Pastikan `api.txt` berisi key AgentRouter, bukan key 9Router.
2. Hapus tanda kutip dan baris tambahan.
3. Jika memakai environment variable, periksa apakah nilai lama masih aktif:

   ```powershell
   $env:AGENTROUTER_API_KEY
   ```

4. Restart proxy setelah mengganti key.

### Test connection berhasil tetapi model merah

Lihat `agentrouter-proxy-error.log`. Jika upstream mengembalikan `503` atau
`all nodes exhausted`, kapasitas provider sedang habis. Restart proxy tidak
memperbaiki kapasitas upstream; tunggu atau gunakan fallback provider di
9Router.

### Streaming berhenti

- Pastikan Base URL mengarah ke proxy, bukan langsung ke AgentRouter.
- Periksa bahwa port `4182` hanya dipakai satu proses.
- Naikkan timeout klien jika prompt atau tool call sangat besar.
- Periksa log untuk `client disconnected` atau timeout upstream.

### Token masih `0/0`

Pastikan memakai versi terbaru repository ini dan restart proxy. Proxy
menormalisasi usage untuk JSON biasa dan chunk SSE terakhir. Upstream tetap
harus mengirim informasi usage.

### Port `4182` sudah dipakai

Gunakan port lain:

```powershell
.\start-agentrouter-proxy.ps1 -Port 4183
```

Ubah Base URL 9Router menjadi:

```text
http://127.0.0.1:4183/v1
```

## Isi repository

| File | Fungsi |
|---|---|
| `agentrouter-proxy.py` | Proxy utama dan transformasi request/response |
| `start-agentrouter-proxy.ps1` | Menjalankan proxy tersembunyi di Windows |
| `stop-agentrouter-proxy.ps1` | Menghentikan proses proxy yang dibuat |
| `watch-agentrouter-proxy.ps1` | Memulihkan proxy Windows jika proses mati |
| `install.cmd` / `install.ps1` | Installer satu langkah untuk Windows |
| `install.sh` | Installer terpandu untuk Linux/macOS |
| `check-setup.py` | Memeriksa health, key, dan endpoint model |
| `api.example.txt` | Contoh file key tanpa credential |
| `tests/test_proxy.py` | Unit test transformasi dan key loading |
| `SECURITY.md` | Panduan menjaga API key dan membatasi akses |

## Batasan

- Proxy ini tidak menyediakan load balancing antar akun AgentRouter.
- Retry tidak dapat mengatasi quota habis atau kapasitas upstream yang lama
  tidak tersedia.
- Daftar model mengikuti `/v1/models` milik AgentRouter dan dapat berubah.
- Header kompatibilitas mungkin perlu diperbarui jika kontrak upstream berubah.

## Lisensi

[MIT](LICENSE)

---

## English quick start

1. Copy `api.example.txt` to `api.txt` and put your AgentRouter API key in it.
2. Run `.\start-agentrouter-proxy.ps1` on Windows, or
   `python agentrouter-proxy.py` on Linux/macOS.
3. Add an OpenAI-compatible provider to 9Router:
   - Base URL: `http://127.0.0.1:4182/v1`
   - API key: any non-empty placeholder such as `local-proxy`
   - Prefix: `ar`
4. Import models from `/models` and test a model.
5. Keep port `4182` private. Read [SECURITY.md](SECURITY.md) before binding to
   a non-loopback address.
