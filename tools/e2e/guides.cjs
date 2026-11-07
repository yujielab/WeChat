// Guides (ui/guides.js): the first time the app opens, a welcome of four cards (Next, Skip, Get started; a
// swipe moves too), once; then tips, one at a time, each pointing at its place — the pages' capsule on the
// Duo, your note — and gone for good once seen; Settings › Show tips again brings them back. Tests see no
// guides unless they ask (localStorage 'ui:guides' = 'on'), so every other suite runs as before.
// npm run dev:e2e; node tools/e2e/guides.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-guides')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),uniq=Math.random().toString(36).slice(2,7)
const UA='Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1'
const duo={viewport:{width:466,height:678},screen:{width:466,height:678},userAgent:UA,isMobile:true,hasTouch:true}

;(async()=>{const browser=await chromium.launch();const errors=[];try{
const ctx=await browser.newContext({locale:'en-US',serviceWorkers:'block',deviceScaleFactor:2,...duo})
await ctx.addInitScript(()=>{try{localStorage.setItem('ui:guides','on')}catch{}})
const p=await ctx.newPage();p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(10000)
await p.goto(BASE);assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username:`gu_${uniq}`,password:'hunter22',display:'Tokio'}),200)
await p.reload();await p.waitForSelector('.shell')

// 1. The welcome: four cards, then gone.
await p.locator('.gd-welcome').waitFor({timeout:6000});await sleep(500)
assert.equal(await p.locator('.gd-title').textContent(),'Your chats');assert.equal(await p.locator('.gd-next').textContent(),'Next')
await p.screenshot({path:path.join(OUT,'1-welcome.png')})
await p.locator('.gd-next').click();await sleep(300);assert.equal(await p.locator('.gd-title').textContent(),'Moments')
await p.locator('.gd-next').click();await sleep(300);await p.locator('.gd-next').click();await sleep(300)
assert.equal(await p.locator('.gd-title').textContent(),'Always in reach');assert.equal(await p.locator('.gd-next').textContent(),'Get started');assert.equal(await p.locator('.gd-skip').isHidden(),true)
await p.locator('.gd-next').click();await p.locator('.gd-welcome').waitFor({state:'detached'})

// 2. Tips, one at a time: the capsule's first (it is there on the Duo), then your note.
await p.locator('.gd-tip').waitFor({timeout:8000});await sleep(400)
assert.equal(await p.locator('.gd-tip').count(),1,'one at a time')
const first=await p.locator('.gd-tip b').textContent()
await p.screenshot({path:path.join(OUT,'2-tip.png')})
const box=await p.locator('.gd-tip').boundingBox();assert.ok(box.x>=11&&box.x+box.width<=466-11&&box.y>=11&&box.y+box.height<=678-11,'inside the screen '+JSON.stringify(box))
await p.locator('.gd-tip-ok').click();await p.locator('.gd-tip').waitFor({state:'detached'})
await p.locator('.gd-tip').waitFor({timeout:8000});const second=await p.locator('.gd-tip b').textContent()
assert.notEqual(second,first,'the next tip');assert.deepEqual([first,second].sort(),['Share a note','Your places'])
await p.screenshot({path:path.join(OUT,'3-tip-note.png')})
// A touch elsewhere puts it away too.
await p.mouse.click(30,640);await p.locator('.gd-tip').waitFor({state:'detached'})

// 3. Once only: back again, nothing.
await p.reload();await p.waitForSelector('.shell');await sleep(4000)
assert.equal(await p.locator('.gd-welcome, .gd-tip').count(),0,'seen: not again')

// 4. Settings › Show tips again: the welcome comes back next time.
await p.evaluate(async()=>(await import('/js/ui/guides.js')).resetGuides())
await p.reload();await p.waitForSelector('.shell');await p.locator('.gd-welcome').waitFor({timeout:6000})
await p.locator('.gd-skip').click();await p.locator('.gd-welcome').waitFor({state:'detached'})

assert.deepEqual(errors,[])
console.log('PASS: the first time, a welcome of four cards (Next, Get started) once; then tips one at a time — the pages\' capsule, your note — each inside the screen, put away by Got it or a touch elsewhere, never again once seen; Show tips again brings the welcome back; no page errors')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
