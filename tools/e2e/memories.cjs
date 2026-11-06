// Memories (views/memories.js, /api/memories): the photos, videos and drawings shared in your chats — yours and
// theirs — kept without anyone saving them. Opened from the pages' capsule on the Duo and from the sidebar: the
// heading (chevron, Memories, "…"), search, tabs (All, Photos, Videos, Drawings), the latest month's recap card,
// then the month and its grid of squares, newest first; a video with its length; a tab narrows it; search finds
// a chat or a person; a tile opens the picture and Escape closes only that; one withdrawn is gone; Oldest first.
// Real accounts against a local dev server.
// npm run dev:e2e; node tools/e2e/memories.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-memories')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),uniq=Math.random().toString(36).slice(2,7)
const UA='Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1'
const duo={viewport:{width:466,height:678},screen:{width:466,height:678},userAgent:UA,isMobile:true,hasTouch:true}

;(async()=>{const browser=await chromium.launch();const errors=[];try{
async function account(u,d,opts){const ctx=await browser.newContext({locale:'en-US',serviceWorkers:'block',deviceScaleFactor:2,...opts});const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${d}] ${e.message}`));p.setDefaultTimeout(10000);await p.goto(BASE);assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username:u,password:'hunter22',display:d}),200);await p.reload();await p.waitForSelector('.shell');return p}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
// A picture drawn in the page, uploaded to the chat and sent as a message.
const sendPicture=(p,room,[w,h],[a,b],type='image')=>p.evaluate(async([room,w,h,a,b,type])=>{const c=document.createElement('canvas');c.width=w;c.height=h;const g=c.getContext('2d');const gr=g.createLinearGradient(0,0,w,h);gr.addColorStop(0,a);gr.addColorStop(1,b);g.fillStyle=gr;g.fillRect(0,0,w,h);g.fillStyle='rgba(255,255,255,.8)';g.beginPath();g.arc(w*.66,h*.38,Math.min(w,h)*.16,0,7);g.fill();const blob=await new Promise(r=>c.toBlob(r,'image/png'));const up=await (await fetch(`/api/media/upload?kind=image&room=${room}&w=${w}&h=${h}`,{method:'POST',headers:{'content-type':'image/png'},body:blob})).json();return (await (await fetch('/api/messages',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({room,type,meta:{url:up.url,w,h}})})).json()).msg},[room,w,h,a,b,type])

const B=await account(`mb_${uniq}`,'Coisini',{viewport:{width:466,height:678}})
const A=await account(`ma_${uniq}`,'Tokio',duo)
const room=(await api(A,'/api/dm',{username:`mb_${uniq}`})).room.id
const p1=await sendPicture(A,room,[1600,1000],['#f6a35b','#6a4c93'])
const p2=await sendPicture(B,room,[1000,1000],['#2a9d8f','#e9c46a'])
await api(A,'/api/messages',{room,type:'text',text:'Words are not memories'})
const p3=await sendPicture(B,room,[900,1200],['#264653','#e76f51'])
const d1=await sendPicture(A,room,[800,800],['#ffffff','#eeeeee'],'drawing')
assert.ok(p1&&p2&&p3&&d1,'sent')
await A.reload();await A.waitForSelector('.row');await sleep(800)

// 1. From the pages' capsule: the heading, search, tabs, the recap, this month and its grid.
await A.locator('.page-item[data-page="memories"]').click();await A.locator('.memories-page .mem-tile').first().waitFor();await sleep(700)
const view=await A.evaluate(()=>{const q=s=>document.querySelector('.memories-page '+s);return{title:q('.mem-title').textContent,tabs:[...document.querySelectorAll('.memories-page .mem-tab')].map(b=>b.textContent),selected:q('.mem-tab[aria-selected="true"]').textContent,recap:q('.mem-recap b')?.textContent,months:[...document.querySelectorAll('.memories-page .mem-month-name')].map(m=>m.textContent),tiles:[...document.querySelectorAll('.memories-page .mem-tile')].map(t=>t.className.replace('mem-tile ',''))}})
const month=new Date().toLocaleString('en-US',{month:'long'})
assert.equal(view.title,'Memories');assert.deepEqual(view.tabs,['All','Photos','Videos','Drawings']);assert.equal(view.selected,'All')
assert.equal(view.recap,`My ${month} recap`);assert.deepEqual(view.months,[`${month}4`])
assert.deepEqual(view.tiles,['is-drawing','is-photo','is-photo','is-photo'],'newest first, theirs and yours, words left out')
assert.equal(await A.locator('.page-item[data-page="memories"]').getAttribute('aria-current'),'page')
await A.screenshot({path:path.join(OUT,'1-memories.png')})

// 2. A tab narrows it; search finds a chat or a person.
await A.locator('.memories-page .mem-tab[data-tab="photo"]').click();await sleep(700)
assert.equal(await A.locator('.memories-page .mem-tile').count(),3,'photos only')
await A.locator('.memories-page .mem-tab[data-tab="drawing"]').click();await sleep(700)
assert.equal(await A.locator('.memories-page .mem-tile').count(),1,'drawings only')
await A.locator('.memories-page .mem-tab[data-tab="all"]').click();await sleep(700)
await A.locator('.mem-search-input').fill('zzz-nobody');await sleep(200)
assert.match(await A.locator('.memories-page .mem-empty').textContent(),/Nothing found/)
await A.locator('.mem-search-input').fill('Coisini');await sleep(200)
assert.equal(await A.locator('.memories-page .mem-tile').count(),4,'the chat with Coisini')
await A.locator('.mem-search-input').fill('');await sleep(200)

// 3. A tile opens the picture; Escape closes only that.
await A.locator('.memories-page .mem-tile.is-photo').first().click();await A.locator('.viewer').waitFor();await sleep(500)
await A.screenshot({path:path.join(OUT,'2-viewer.png')})
await A.keyboard.press('Escape');await A.locator('.viewer').waitFor({state:'detached'});await sleep(200)
assert.equal(await A.locator('.memories-page').count(),1,'still on Memories')

// 4. Oldest first; one withdrawn is gone next time.
await A.locator('.memories-page .mem-more').click();await A.locator('.menu .menu-item:has-text("Oldest first")').click()
await A.waitForFunction(()=>document.querySelectorAll('.memories-page .mem-recap').length===0)
assert.equal(await A.locator('.memories-page .mem-tile').first().getAttribute('class'),'mem-tile is-photo')
assert.equal(await A.locator('.memories-page .mem-recap').count(),0,'no recap out of order')
await api(A,'/api/revoke',{id:p1.id,room})
await A.locator('.page-item[data-page="chats"]').click();await A.locator('.memories-page').waitFor({state:'detached'});await sleep(400)

// 5. From the sidebar too.
await A.locator('.page-item[data-page="menu"]').click();await sleep(700)
await A.locator('.side-memories').click();await A.locator('.memories-page .mem-tile').first().waitFor();await sleep(500)
assert.equal(await A.locator('.memories-page .mem-tile').count(),3,'the withdrawn one is gone')

// 6. Dark.
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('dark'));await sleep(500)
await A.screenshot({path:path.join(OUT,'3-dark.png')})

assert.deepEqual(errors,[],'no page errors')
console.log('PASS: Memories from the pages\' capsule and the sidebar: the heading, search, tabs, the month\'s recap card, the month with its grid, newest first, yours and theirs, words left out; Photos and Drawings narrow it; search finds the chat or nothing; a tile opens the picture and Escape closes only that; Oldest first without the recap; a withdrawn one gone; dark')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
