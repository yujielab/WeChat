#!/usr/bin/env node
// Runs the UI + Worker locally against the mock WeChat server.
//   npm run dev:mock            → http://127.0.0.1:8787  (password: demo)
//   MOCK_AUTO=1 npm run dev:mock  scans and confirms the QR code automatically

import { spawn } from 'node:child_process'

const MOCK_PORT = process.env.MOCK_PORT || '8790'
const PORT = process.env.PORT || '8787'

const children = []
const run = (cmd, args, env = {}) => {
  const child = spawn(cmd, args, { stdio: 'inherit', env: { ...process.env, ...env } })
  children.push(child)
  child.on('exit', code => {
    for (const c of children) if (c !== child) c.kill()
    process.exit(code ?? 0)
  })
}

run(process.execPath, ['tools/mock-wx.mjs'], { MOCK_PORT })
run('npx', [
  'wrangler', 'dev',
  '--ip', '127.0.0.1',
  '--port', PORT,
  '--var', `WX_MOCK_ORIGIN:http://127.0.0.1:${MOCK_PORT}`,
  '--var', `APP_PASSWORD:${process.env.APP_PASSWORD || 'demo'}`,
  '--var', 'ALARM_SUBREQUESTS:1000'
])

for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => children.forEach(c => c.kill(sig)))
