# Security

## Menyimpan API key

- Cara yang direkomendasikan: simpan key pada field API Key connection 9Router.
- Proxy meneruskan Bearer token tersebut per request dan tidak menuliskannya ke
  log atau file.
- Jangan commit `api.txt`, `.env`, log, atau screenshot yang menampilkan key.
- `api.txt` sudah tercantum di `.gitignore`.
- `api.txt` dan `AGENTROUTER_API_KEY` hanya fallback opsional untuk klien yang
  tidak dapat mengirim header Authorization.
- Jika key pernah masuk commit atau log publik, segera revoke dan buat key baru.

## Membatasi akses proxy

Proxy tidak menyediakan autentikasi untuk klien yang masuk. Secara default ia
hanya listen di `127.0.0.1`, sehingga hanya aplikasi di komputer yang sama yang
dapat menggunakannya.

Jangan menjalankan proxy dengan `--host 0.0.0.0` pada komputer yang dapat
diakses publik tanpa firewall atau reverse proxy berautentikasi. Siapa pun yang
dapat menjangkau port proxy dapat mengirim request ke AgentRouter. Jika fallback
key dikonfigurasi, mereka juga dapat memakai fallback tersebut tanpa mengetahui
nilainya.

## Melaporkan kerentanan

Jangan membuka issue publik yang menyertakan API key, token, alamat pribadi,
atau isi request sensitif. Cabut credential yang terdampak terlebih dahulu,
lalu kirim laporan tanpa secret kepada pemilik repository.
