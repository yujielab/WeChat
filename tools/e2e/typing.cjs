// The live typing preview never stops short: typed quickly, the other side sees the whole text, not the first few
// characters (the throttle used to drop the last update of a burst). Two real accounts against the local server.
// npm run dev:e2e; node tools/e2e/typing.cjs
const{chromium}=require('playwright'),assert=require('node:assert/strict')
const BASE=process.env.BASE||'http://127.0.0.1:8787'
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server')
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const uniq=Date.now().toString(36)

;(async()=>{const browser=await chromium.launch();try{
const errors=[]
async function account(username){
  const p=await (await browser.newContext({viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block'})).newPage()
  p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(10000);await p.goto(BASE)
  assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username,password:'hunter22',display:username}),200)
  await p.reload();await p.waitForSelector('.shell');return p
}
const A=await account(`ya_${uniq}`),B=await account(`yb_${uniq}`)
const room=await A.evaluate(async u=>(await (await fetch('/api/dm',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({username:u})})).json()).room.id,`yb_${uniq}`)
await B.evaluate(async room=>fetch('/api/messages',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({room,type:'text',text:'在吗'})}),room)
for(const p of [A,B]){await p.reload();await p.waitForSelector(`.row[data-id="${room}"]`);await p.locator(`.row[data-id="${room}"] .row-inner`).click();await p.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(300)}
const ghost=()=>B.evaluate(()=>document.querySelector('.thread:not([hidden]) .ghost-row .bubble')?.textContent||'')
const field=A.locator('.thread:not([hidden]) .composer textarea')
await field.click()
// Quick bursts, each ending well inside the throttle.
await field.type('明天下午见',{delay:20});await sleep(600)
assert.equal(await ghost(),'明天下午见','the whole of a quick burst')
await field.type('，带伞',{delay:15});await sleep(600)
assert.equal(await ghost(),'明天下午见，带伞')
await field.press('Backspace');await field.press('Backspace');await sleep(600)
assert.equal(await ghost(),'明天下午见，','deleting too')
// Sent: the preview goes, and nothing late brings it back.
await field.press('Enter');await sleep(700)
assert.equal(await ghost(),'','gone once sent')
assert.deepEqual(errors,[])
console.log('PASS: the live typing preview shows the whole of a quick burst (typing and deleting), and nothing late brings it back after sending')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
