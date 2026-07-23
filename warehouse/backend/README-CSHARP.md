# Warehouse Backend (C# ASP.NET Core)

Backend REST API untuk menghubungkan aplikasi Flutter dengan SQL Server menggunakan ASP.NET Core Minimal API.

## Setup

1. Pastikan `.env` ada dan terisi dengan konfigurasi database:
   ```env
   DB_SERVER=10.83.33.103
   DB_DATABASE=promosys
   DB_USER=sa
   DB_PASSWORD=sa
   API_KEY=change-me
   PORT=3001
   ```

2. Restore dependencies:
   ```bash
   dotnet restore
   ```

3. Jalankan:
   ```bash
   dotnet run
   ```
   atau untuk development dengan hot reload:
   ```b
   dotnet watch runash
   ```

## Endpoint

- `GET /`
  - Health check, return `{ "status": "ok", "message": "Warehouse backend is running" }`

- `GET /api/models`
  - Mengambil daftar model (`ProductName`) dari SQL Server
  - Memerlukan header `x-api-key` dengan nilai dari `.env` API_KEY
  - Return: JSON array dengan ProductName dan field lainnya

## Keamanan

- API memerlukan header `x-api-key`
- Set `API_KEY` di `.env` dan jangan commit file `.env`
- Backend menyimpan kredensial database hanya di server, bukan di aplikasi Flutter

## Notes for Flutter

- Flutter menggunakan `lib/config.dart` untuk `API_BASE_URL` dan `API_KEY`
- Default: `http://10.83.33.103:3001`
- Jalankan Flutter dengan `dart-define` jika perlu override:
  ```bash
  flutter run --dart-define=API_BASE_URL=http://10.83.33.103:3001 \
    --dart-define=API_KEY=your_api_key_here
  ```

## Teknologi

- ASP.NET Core Minimal API (.NET 10)
- Microsoft.Data.SqlClient untuk koneksi SQL Server
- CORS enabled untuk Flutter app

## Deployment

Untuk deployment di Windows:
1. Gunakan `dotnet publish -c Release`
2. Deploy folder `bin/Release/net10.0/publish` ke server
3. Buat Windows Service atau gunakan `nssm` / `pm2` untuk auto-start
