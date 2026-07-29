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
   │  forward 9Router API key + adapt request/response
   ▼
https://agentrouter.org/v1
```

## Fitur

- Mengambil API key AgentRouter langsung dari field API Key milik 9Router.
- Mendukung `api.txt`/environment variable hanya sebagai fallback opsional.
- Menambahkan header kompatibilitas yang dibutuhkan endpoint AgentRouter.
- Menghapus field JSON bernilai `null`.
- Menambahkan `stream_options.include_usage=true` pada request streaming.
- Meneruskan SSE per event tanpa menunggu buffer besar terisi.
- Menghapus event `billing.summary` dari stream chat.
- Mengubah error di dalam HTTP 200 SSE menjadi HTTP error agar fallback aktif.
- Menutup stream jika error muncul setelah streaming dimulai, tanpa false `[DONE]`.
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
- Windows PowerShell untuk watchdog saat login, atau Linux dengan `systemd`
  untuk service dan health watchdog. macOS dapat menjalankan file Python
  secara langsung.

## Instalasi cepat di Windows

### Cara termudah

Setelah clone, klik dua kali:

```text
install.cmd
```

Installer akan:

1. memeriksa Python 3.11+;
2. menjalankan seluruh unit test;
3. menyalakan dan memverifikasi proxy;
4. memasang watchdog saat login Windows;
5. menampilkan nilai yang perlu dimasukkan ke 9Router.

Installer tidak meminta atau menyimpan API key. Key dimasukkan langsung ke
dashboard 9Router.

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

### 3. Jalankan proxy secara manual

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

### 4. Tambahkan provider di 9Router

Buka dashboard 9Router, lalu buat provider **OpenAI Compatible** dengan nilai:

| Field | Nilai |
|---|---|
| Name | `AgentRouter Local` |
| Prefix | `ar` |
| API Type | `Chat Completions` |
| Base URL | `http://127.0.0.1:4182/v1` |
| API Key (for Check) | API key AgentRouter yang sebenarnya |
| Model ID untuk test | `claude-opus-5` |

9Router menyimpan key sebagai credential provider lalu mengirimkannya melalui
header `Authorization`. Proxy meneruskan key tersebut ke AgentRouter tanpa
menuliskannya ke log atau file proxy.

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

### 5. Hentikan atau hapus pemasangan

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
  --upstream https://agentrouter.org
```

Di Linux/macOS, instalasi terpandu tersedia:

```bash
chmod +x install.sh
./install.sh
```

Di Linux yang memakai `systemd`, perintah tersebut otomatis memasang service
yang aktif saat boot, restart saat proses mati, dan diperiksa health-nya setiap
30 detik. Instalasi manual yang setara:

```bash
chmod +x install-systemd.sh
./install-systemd.sh
```

Jika 9Router berada di Docker bridge dan perlu mengakses alamat host:

```bash
./install-systemd.sh --host 0.0.0.0
```

Batasi port `4182` dengan firewall. Untuk menghapus service:

```bash
./install-systemd.sh --uninstall
```

Pada Linux tanpa `systemd` atau macOS, `install.sh` memakai proses background.
Gunakan `./install.sh --background` untuk memilih mode tersebut secara
eksplisit.

Pilihan command line:

```text
--host       Alamat listen. Default: 127.0.0.1
--port       Port listen. Default: 4182
--upstream   URL AgentRouter. Harus HTTPS.
--key-file   File key fallback opsional. Default: ./api.txt
```

### Fallback key opsional

Cara yang direkomendasikan adalah menyimpan key di 9Router. Untuk klien yang
tidak dapat mengirim header `Authorization`, proxy masih mendukung fallback:

```powershell
Copy-Item .\api.example.txt .\api.txt
notepad .\api.txt
```

Atau:

```powershell
$env:AGENTROUTER_API_KEY = "YOUR_AGENTROUTER_API_KEY"
```

Key inbound dari 9Router selalu memiliki prioritas di atas fallback.

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

1. Pastikan field API Key pada provider 9Router berisi key AgentRouter yang
   sebenarnya, bukan key 9Router dan bukan `local-proxy`.
2. Edit connection atau tambahkan key baru setelah key AgentRouter dirotasi.
3. Jika memakai fallback environment variable, periksa nilai yang aktif:

   ```powershell
   $env:AGENTROUTER_API_KEY
   ```

4. Restart proxy hanya diperlukan jika mengganti fallback file/environment.
   Perubahan key di dashboard 9Router berlaku untuk request berikutnya.

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
menormalisasi usage untuk JSON biasa dan chunk SSE terakhir. Jika AgentRouter
mengirim event error di dalam HTTP 200 SSE, proxy mengubahnya menjadi error
nyata agar 9Router tidak lagi mencatat false-success `0/0`.

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
| `install.sh` | Installer otomatis Linux/macOS; memilih systemd bila tersedia |
| `install-systemd.sh` | Service Linux dengan auto-restart dan health watchdog |
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

1. Run `install.cmd` on Windows, or `./install.sh` on Linux/macOS.
2. The installer starts the proxy without asking for a secret.
3. Add an OpenAI-compatible provider to 9Router:
   - Base URL: `http://127.0.0.1:4182/v1`
   - API key: your real AgentRouter API key
   - Prefix: `ar`
4. Import models from `/models` and test a model.
5. You may alternatively run `.\start-agentrouter-proxy.ps1` on Windows, or
   `python agentrouter-proxy.py` on Linux/macOS.
6. Keep port `4182` private. Read [SECURITY.md](SECURITY.md) before binding to
   a non-loopback address.
