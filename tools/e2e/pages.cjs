// Pages (ui/pages.js): on the iPhone Duo, a capsule of the app's places at the foot of the system's column —
// Chats, Moments, Memories, Requests, You, Menu — with the current one marked by a circle that glides to it. It switches
// pages in place: from page to page there is only ever one page up (the next fades in over the same scrim), it
// stays in reach over every page, Chats and Menu are the list and the sidebar; the list's Search and New chat
// keep to the head of the column. A conversation has the column to itself, and so does anything opened over a
// page. No rail on an ordinary phone. Real accounts against a local dev server.
// npm run dev:e2e; node tools/e2e/pages.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-pages')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),uniq=Math.random().toString(36).slice(2,7)
const UA='Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1'
const duo={viewport:{width:466,height:678},screen:{width:466,height:678},userAgent:UA,isMobile:true,hasTouch:true}

;(async()=>{const browser=await chromium.launch();const errors=[];try{
async function account(u,d,opts){const ctx=await browser.newContext({locale:'en-US',serviceWorkers:'block',deviceScaleFactor:2,...opts});const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${d}] ${e.message}`));p.setDefaultTimeout(10000);await p.goto(BASE);assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username:u,password:'hunter22',display:d}),200);await p.reload();await p.waitForSelector('.shell');return p}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
const rail=p=>p.evaluate(()=>{const r=document.querySelector('.page-rail');const cur=r.querySelector('.page-item.current');const t=r.querySelector('.page-thumb');return{shown:!r.hidden&&getComputedStyle(r).display!=='none',items:[...r.querySelectorAll('.page-item')].map(b=>b.dataset.page),current:cur?.dataset.page,aria:cur?.getAttribute('aria-current'),thumbOn:cur?Math.abs(new DOMMatrix(getComputedStyle(t).transform).m42-cur.offsetTop)<1:false,pageSheets:document.querySelectorAll('#overlays .sheet.page-sheet').length}})
const settle=p=>p.waitForFunction(()=>{const t=document.querySelector('.page-thumb'),c=document.querySelector('.page-item.current');return !c||Math.abs(new DOMMatrix(getComputedStyle(t).transform).m42-c.offsetTop)<1},null,{timeout:4000})

const B=await account(`gb_${uniq}`,'Coisini',{viewport:{width:466,height:678}})
const A=await account(`ga_${uniq}`,'Tokio',duo)
const room=(await api(A,'/api/dm',{username:`gb_${uniq}`})).room.id
await api(A,'/api/messages',{room,type:'text',text:'Morning!'});await api(B,'/api/messages',{room,type:'text',text:'Hey there'})
await A.reload();await A.waitForSelector('.row');await sleep(900)

// 1. The rail: the five places, Chats current; the list's own rail above it (Back at its head; Search beside the title).
let r=await rail(A)
assert.equal(r.shown,true,'a rail on the Duo');assert.deepEqual(r.items,['chats','moments','memories','requests','you','menu'])
assert.equal(await A.evaluate(()=>getComputedStyle(document.querySelector('.list-moments')).display),'none','no second Moments beside the title: it is in the capsule')
assert.equal(r.current,'chats');assert.equal(r.aria,'page')
const listRail=await A.evaluate(()=>{const top=document.querySelector('.pane-list .duo-rail');const pr=document.querySelector('.page-rail').getBoundingClientRect();const items=[...document.querySelectorAll('.pane-list .duo-rail .bar-item:not([hidden])')].map(b=>({id:b.dataset.item,bottom:b.getBoundingClientRect().bottom}));return{inTop:[...top.querySelectorAll('.bar-item')].map(b=>b.dataset.item),clear:items.every(i=>i.bottom<=pr.top)}})
assert.deepEqual(listRail.inTop,['back'],'Back where every column has it; Search beside the title');assert.ok(listRail.clear,'clear of the pages')
await A.screenshot({path:path.join(OUT,'1-chats.png')})

// 2. Moments: a page, the rail still there over it, Moments current.
await A.locator('.page-item[data-page="moments"]').click();await A.locator('.moments-home.page-sheet').waitFor();await settle(A);await sleep(400)
r=await rail(A);assert.equal(r.shown,true,'still in reach');assert.equal(r.current,'moments');assert.equal(r.thumbOn,true,'the circle went with it')
// The list's own rail steps aside under the page (the edge column is the pages').
assert.equal(await A.evaluate(()=>getComputedStyle(document.querySelector('.pane-list > .duo-rail')).visibility),'hidden','the list rail steps aside over a page')
await A.screenshot({path:path.join(OUT,'2-moments.png')})

// 3. You, then Requests: each takes the other's place — one page up at a time.
await A.locator('.page-item[data-page="you"]').click();await A.locator('.moments-profile.page-sheet').waitFor();await sleep(500)
r=await rail(A);assert.equal(r.current,'you');assert.equal(r.pageSheets,1,'Moments made way');assert.equal(await A.locator('.moments-home').count(),0)
await A.locator('.page-item[data-page="requests"]').click();await A.locator('.requests-sheet.page-sheet').waitFor();await sleep(500)
r=await rail(A);assert.equal(r.current,'requests');assert.equal(r.pageSheets,1)
await A.screenshot({path:path.join(OUT,'3-requests.png')})

// 4. Menu: the pages go, the sidebar has the screen; Chats: the list again.
await A.locator('.page-item[data-page="menu"]').click();await A.locator('.requests-sheet').waitFor({state:'detached'});await sleep(700)
assert.equal(await A.evaluate(()=>document.querySelector('.pane-sidebar').dataset.role),'single','the sidebar')
r=await rail(A);assert.equal(r.current,'menu');assert.equal(r.pageSheets,0)
await A.screenshot({path:path.join(OUT,'4-menu.png')})
await A.locator('.page-item[data-page="chats"]').click();await sleep(700)
assert.equal(await A.evaluate(()=>document.querySelector('.pane-list').dataset.role),'single','the list');assert.equal((await rail(A)).current,'chats')

// 5. A page's own Close: back to the column it was over.
await A.locator('.page-item[data-page="moments"]').click();await A.locator('.moments-home').waitFor();await sleep(400)
await A.locator('.moments-home .mo-head-actions [aria-label="Close"]').click();await A.locator('.moments-home').waitFor({state:'detached'});await sleep(300)
assert.equal((await rail(A)).current,'chats')
assert.equal(await A.evaluate(()=>getComputedStyle(document.querySelector('.pane-list > .duo-rail')).visibility),'visible','and comes back once it goes')

// 6. Something opened over a page has the screen: no rail; it comes back when that goes.
await A.locator('.page-item[data-page="moments"]').click();await A.locator('.moments-home').waitFor();await sleep(400)
await A.locator('.moments-home .mo-add').click();await A.locator('.moments-editor').waitFor();await sleep(300)
assert.equal((await rail(A)).shown,false,'the editor has the screen')
await A.locator('.me-cancel').click();await A.locator('.moments-editor').waitFor({state:'detached'});await sleep(300)
assert.equal((await rail(A)).shown,true)
await A.locator('.page-item[data-page="chats"]').click();await A.locator('.moments-home').waitFor({state:'detached'});await sleep(400)

// 7. A conversation keeps the column to itself; back on the list, the rail returns.
await A.locator('.row .row-inner').first().click();await A.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(600)
assert.equal((await rail(A)).shown,false,'the conversation\'s own rail')
await A.locator('.thread:not([hidden]) [data-item="back"]').click();await sleep(700)
assert.equal((await rail(A)).shown,true);assert.equal((await rail(A)).current,'chats')

// 8. Requests show their count on the bell.
await api(B,'/api/contacts/add',{username:`ga_${uniq}`});await sleep(1500)
assert.equal(await A.locator('.page-item[data-page="requests"] .page-badge').textContent(),'1')

// 9. Dark.
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('dark'));await sleep(400)
await A.locator('.page-item[data-page="you"]').click();await A.locator('.moments-profile').waitFor();await sleep(600)
await A.screenshot({path:path.join(OUT,'5-you-dark.png')})

// 10. An ordinary phone: no rail.
const P=await account(`gp_${uniq}`,'Phone',{viewport:{width:393,height:852},isMobile:true,hasTouch:true});await sleep(600)
assert.equal((await rail(P)).shown,false,'no system column, no rail')

assert.deepEqual(errors,[],'no page errors')
console.log('PASS: on the Duo the pages\' capsule at the foot of the column (Chats, Moments, Memories, Requests, You, Menu), Chats current with the circle on it; the list\'s Search and New chat at the head; Moments as a page with the capsule still in reach; You and Requests each in the other\'s place, one page up at a time; Menu the sidebar, Chats the list; a page\'s own Close back to its column; nothing over a page under it; a conversation with the column to itself; a count on the bell; dark; no rail on a phone')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
