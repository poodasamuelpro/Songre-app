// bff-vercel/api/bff/health.ts
import type { VercelRequest, VercelResponse } from '@vercel/node';

export default function handler(_req: VercelRequest, res: VercelResponse): void {
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({ ok: true, service: 'SONGRE BFF (Vercel)', version: '1.0.0' });
}
