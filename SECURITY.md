# Security

## Menyimpan API key

- Jangan commit `api.txt`, `.env`, log, atau screenshot yang menampilkan key.
- `api.txt` sudah tercantum di `.gitignore`.
- Alternatifnya, gunakan environment variable `AGENTROUTER_API_KEY`.
- Jika key pernah masuk commit atau log publik, segera revoke dan buat key baru.

## Membatasi akses proxy

Proxy tidak menyediakan autentikasi untuk klien yang masuk. Secara default ia
hanya listen di `127.0.0.1`, sehingga hanya aplikasi di komputer yang sama yang
dapat menggunakannya.

Jangan menjalankan proxy dengan `--host 0.0.0.0` pada komputer yang dapat
diakses publik tanpa firewall atau reverse proxy berautentikasi. Siapa pun yang
dapat menjangkau port proxy dapat memakai API key AgentRouter yang disimpan.

## Melaporkan kerentanan

Jangan membuka issue publik yang menyertakan API key, token, alamat pribadi,
atau isi request sensitif. Cabut credential yang terdampak terlebih dahulu,
lalu kirim laporan tanpa secret kepada pemilik repository.
