// The message banner (views/banner.js): a message for a conversation that isn't on screen drops in from the top.
// On the list it goes by itself after 1.5 s; over a sheet (Moments) a pull down opens a field and it stays while an
// answer is written, which goes to that conversation without leaving the sheet; a tap opens the conversation (the
// sheet closed); none for the conversation being read; another conversation's message over it, flicked away up;
// dark. Three real accounts against the local server.
// npm run dev:e2e; node tools/e2e/banner.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-banner')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),uniq=Date.now().toString(36)

;(async()=>{const browser=await chromium.launch();const errors=[];try{
async function account(u,d){const ctx=await browser.newContext({viewport:{width:466,height:678},locale:'en-US',serviceWorkers:'block',deviceScaleFactor:2});const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${d}] ${e.message}`));p.setDefaultTimeout(10000);await p.goto(BASE);assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username:u,password:'hunter22',display:d}),200);await p.reload();await p.waitForSelector('.shell');return p}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,body===undefined?{}:{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
const A=await account(`ba_${uniq}`,'Tokio'),B=await account(`bb_${uniq}`,'Coisini'),C=await account(`bc_${uniq}`,'Mira')
const withB=(await api(A,'/api/dm',{username:`bb_${uniq}`})).room.id,withC=(await api(A,'/api/dm',{username:`bc_${uniq}`})).room.id
await api(A,'/api/messages',{room:withB,type:'text',text:'Hey'});await api(A,'/api/messages',{room:withC,type:'text',text:'Hi'})
const say=(p,room,text)=>api(p,'/api/messages',{room,type:'text',text})
await A.reload();await A.waitForSelector(`.row[data-id="${withB}"]`);await sleep(800)
const away=()=>A.mouse.move(4,640) // (a mouse resting on the banner keeps it: keep it off)
const banner=()=>A.evaluate(()=>{const b=document.querySelector('#overlays > .banner:not(.leaving)');if(!b)return null;const r=b.getBoundingClientRect();return{name:b.querySelector('.banner-name').textContent,text:b.querySelector('.banner-body').textContent,open:b.classList.contains('open'),top:r.top,left:r.left,right:r.right,bottom:r.bottom,cx:r.left+r.width/2,cy:r.top+r.height/2,onTop:b.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2))}})
const arrives=async()=>{await A.waitForSelector('#overlays > .banner:not(.off):not(.leaving)');await sleep(450);return banner()}
const gone=(ms)=>A.waitForSelector('#overlays > .banner',{state:'detached',timeout:ms})
const drag=async(b,dy)=>{await A.mouse.move(b.cx,b.cy);await A.mouse.down();for(let i=1;i<=8;i++){await A.mouse.move(b.cx,b.cy+dy*i/8);await sleep(16)}await A.mouse.up()}

// 1. On the list: who and what, at the top, centred; gone by itself after 1.5 s.
await away()
await say(B,withB,'Are you around?')
let b=await arrives();const t0=Date.now()-450
assert.equal(b.name,'Coisini');assert.equal(b.text,'Are you around?')
assert.ok(b.top>=0&&b.top<40,`at the top (${b.top})`);assert.ok(Math.abs((b.left+b.right)/2-233)<2,'centred');assert.ok(b.onTop,'nothing over it')
await A.screenshot({path:path.join(OUT,'1-list.png')})
await sleep(600);assert.ok(await banner(),'still there at 1 s')
await gone(1600);const took=Date.now()-t0
assert.ok(took>1300&&took<2300,`went by itself after about 1.5 s (${took} ms)`)

// 2. Over a sheet (Moments): above it; a pull down opens the field, and it stays while you write.
await A.locator('.list-moments').click();await A.locator('.moments-home').waitFor();await sleep(600);await away()
await say(B,withB,'Lunch at 1?')
b=await arrives();assert.ok(b.onTop,'over the sheet')
await drag(b,80)
await A.waitForSelector('#overlays > .banner.open');await sleep(350)
assert.equal(await A.evaluate(()=>document.activeElement?.classList.contains('banner-input')),true,'the field takes the keys')
assert.equal(await A.locator('.banner-input').getAttribute('placeholder'),'Reply to Coisini')
await A.screenshot({path:path.join(OUT,'2-reply.png')})
await sleep(1800);assert.ok((await banner())?.open,'no 1.5 s while answering')
await A.keyboard.type('On my way',{delay:15})
await A.screenshot({path:path.join(OUT,'3-typed.png')})
await A.keyboard.press('Enter')
await gone(1500)
assert.ok(await A.locator('.moments-home').isVisible(),'answered without leaving the sheet')
await sleep(500)
const sent=await api(B,`/api/messages?room=${withB}&limit=20`)
assert.ok(JSON.stringify(sent).includes('On my way'),'the answer reached the conversation')

// 3. A tap: the conversation, with the sheet closed.
await say(B,withB,'Great, see you')
b=await arrives()
await A.mouse.click(b.cx,b.cy)
await gone(800)
await A.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(500)
assert.equal(await A.locator('.moments-home').count(),0,'the sheet closed')
assert.ok((await A.locator('.thread:not([hidden]) .thread-title').textContent()).includes('Coisini'),'her conversation')
assert.ok(await A.locator('.thread:not([hidden]) .msgs').getByText('Great, see you').isVisible())

// 4. The conversation being read: no banner, the message is right there.
await away();await say(B,withB,'Here now')
await A.locator('.thread:not([hidden]) .msgs').getByText('Here now').waitFor();await sleep(700)
assert.equal(await banner(),null,'none for the conversation on screen')

// 5. Another conversation's message: a banner over this one; flicked up, gone at once.
await say(C,withC,'Got a minute?')
b=await arrives();assert.equal(b.name,'Mira')
const t1=Date.now();await drag(b,-70);await gone(700)
assert.ok(Date.now()-t1<900,'flicked away')
assert.ok((await A.locator('.thread:not([hidden]) .thread-title').textContent()).includes('Coisini'),'still in her conversation')

// 6. Dark.
await A.evaluate(()=>{document.documentElement.dataset.theme='dark'});await away()
await say(C,withC,'Dinner tonight? I found a new place near the river, they do a great tasting menu.')
b=await arrives();await drag(b,80);await A.waitForSelector('#overlays > .banner.open');await sleep(400)
await A.screenshot({path:path.join(OUT,'4-dark.png')})
await A.keyboard.press('Escape');await gone(800)

assert.deepEqual(errors,[])
console.log('PASS: a message from elsewhere drops in at the top — on the list gone by itself after about 1.5 s; over a sheet, a pull down opens a field that stays while answering, and the answer reaches the conversation without leaving the sheet; a tap opens the conversation with the sheet closed; none for the conversation being read; another conversation\'s, flicked away up; dark')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
