import 'dotenv/config';
import express from 'express';
import { Mt5Client } from './server/mt5Client.js';
import { runBot, stopBot, isRunning, getLogs, closeSymbol } from './server/botRunner.js';
import { BOT_CONFIG } from './server/config.js';

const app = express();
app.use(express.json());

const client = new Mt5Client();

app.get('/api/status', async (_, res) => {
  const account = await client.getAccount();
  const positions = await client.getPositions();
  res.json({
    running: isRunning(),
    connected: !!account,
    account,
    positions,
    uptime: process.uptime(),
  });
});

app.get('/api/logs', (_, res) => {
  res.json({ logs: getLogs() });
});

app.post('/api/toggle', async (_, res) => {
  if (isRunning()) {
    stopBot();
  } else {
    runBot(client);
  }
  res.json({ running: isRunning() });
});

app.post('/api/close/:symbol', async (req, res) => {
  const ok = await closeSymbol(client, req.params.symbol);
  res.json({ closed: ok });
});

app.get('/api/signals', (_, res) => {
  res.json({ symbols: BOT_CONFIG.symbols });
});

const PORT = parseInt(process.env.PORT || '3000', 10);
app.listen(PORT, () => {
  console.log(`v9-mt5-bot listening on :${PORT}`);
  runBot(client);
});
