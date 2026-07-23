# Warehouse Backend

Backend REST API untuk menghubungkan aplikasi Flutter dengan SQL Server.

## Setup

1. Salin file `.env.example` menjadi `.env`.
2. Isi `DB_DATABASE` dengan nama database SQL Server kamu.
3. Jalankan:

```bash
cd backend
npm install
npm run dev
```

## Endpoint

- `GET /api/models`
  - Mengambil daftar model (`ProductName`) dari SQL Server.

## Keamanan

- API sekarang memerlukan header `x-api-key`.
- Set `API_KEY` di `.env` dan jangan commit file `.env`.
- Backend menyimpan kredensial database hanya di server, bukan di aplikasi Flutter.

## Notes for Flutter

- Flutter menggunakan `lib/config.dart` untuk `API_BASE_URL` dan `API_KEY`.
- Jalankan Flutter dengan `dart-define` untuk menghindari menyimpan token di kode:

```bash
flutter run --dart-define=API_BASE_URL=http://10.83.33.103:3000 \
  --dart-define=API_KEY=your_api_key_here
```

- Jika pakai emulator Android, default `API_BASE_URL` adalah `http://10.0.2.2:3000`.
