import express from 'express';
import cors from 'cors';
import dotenv from 'dotenv';
import modelsRouter from './routes/models.js';

dotenv.config();

const apiKey = process.env.API_KEY;
const app = express();
app.use(cors());
app.use(express.json());

app.use((req, res, next) => {
  if (req.path.startsWith('/api/')) {
    const requestKey = req.header('x-api-key');
    if (!apiKey || requestKey !== apiKey) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
  }
  next();
});

app.get('/', (req, res) => {
  res.json({ status: 'ok', message: 'Warehouse backend is running' });
});

app.use('/api/models', modelsRouter);

const port = process.env.PORT || 3000;
const host = '0.0.0.0';
app.listen(port, host, () => {
  console.log(`Warehouse backend listening on http://0.0.0.0:${port}`);
  console.log(`(Akses dari device: http://<your-pc-ip>:${port})`);
});
