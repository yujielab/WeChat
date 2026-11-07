// The side rail, against the local server with real accounts. Where the system keeps its column down the right
// edge (the iPhone Duo full screen, iOS 27.2's early wide viewport) the controls stand in it as a rail — in the
// list Back, Search and New Chat, in the conversation Back, the calls and the details, in the details Back, in
// the sidebar Search and New Chat, on the drawing board Close, Send, Undo and Clear — and content stops at the
// column; search opens its field above the list with Cancel at the head of the rail. Everywhere else (an ordinary
// phone) there is no rail: the bars stay at each column's foot. Unfolded, the leading column keeps its bar and
// the trailing one has the rail. The two follow the window as it changes.
// npm run dev:e2e; node tools/e2e/rail.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-rail')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const uniq=Date.now().toString(36)
const UA='Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1'

;(async()=>{const browser=await chromium.launch();try{
const errors=[]
async function account(username,display,opts,init){
  const ctx=await browser.newContext({locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:2,...opts})
  const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${display}] ${e.message}`));p.setDefaultTimeout(10000)
  if(init)await p.addInitScript(init)
  await p.goto(BASE)
  assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username,password:'hunter22',display}),200)
  await p.reload();await p.waitForSelector('.shell')
  return p
}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
// The Duo's outer display, full screen: iOS Safari 27.2, a 466 × 678 screen, the early wide viewport.
const duo={viewport:{width:466,height:678},screen:{width:466,height:678},userAgent:UA,isMobile:true,hasTouch:true}
const phone={viewport:{width:393,height:852},isMobile:true,hasTouch:true}
const inner={viewport:{width:890,height:626},isMobile:true,hasTouch:true}
// The inner display's system column, as a right safe area (the init script runs in the page: no closures).
const safeRight84=()=>document.addEventListener('DOMContentLoaded',()=>document.documentElement.style.setProperty('--safe-right','84px'))

const D=await account(`da_${uniq}`,'小明',duo),B=await account(`db_${uniq}`,'小红',{viewport:{width:466,height:678}})
const room=(await api(D,'/api/dm',{username:`db_${uniq}`})).room.id
for(const t of['在吗','明天下午三点见'])await api(B,'/api/messages',{room,type:'text',text:t})
const P=await account(`dp_${uniq}`,'小刚',phone);await P.context().addCookies(await D.context().cookies());await P.reload();await P.waitForSelector('.row')
const U=await account(`du_${uniq}`,'小李',inner,safeRight84);await U.context().addCookies(await D.context().cookies());await U.reload();await U.waitForSelector('.row')
await D.reload();await D.waitForSelector('.row');await sleep(700)

// What is in the rail, top to bottom, and where it stands.
const rail=(p,sel)=>p.evaluate(sel=>{const r=document.querySelector(sel);if(!r||getComputedStyle(r).display==='none')return null;const b=r.getBoundingClientRect();return{left:b.left,right:b.right,top:b.top,bottom:b.bottom,items:[...r.querySelectorAll('.bar-item')].filter(e=>e.getClientRects().length).map(e=>{const q=e.getBoundingClientRect();return{id:e.dataset.item||'more',x:q.x,y:q.y,w:q.width,h:q.height}})}},sel)
const ids=r=>r.items.map(i=>i.id)
const axis=p=>p.evaluate(()=>document.documentElement.dataset.bars)
const open=async p=>{await p.locator('.row .row-inner').first().click();await p.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(700)}

// 1. The Duo, full screen: the list's rail, and its rows stop at the column.
assert.equal(await D.evaluate(()=>document.documentElement.dataset.wide),'outer');assert.equal(await axis(D),'vertical')
let r=await rail(D,'.pane-list > .duo-rail');assert.ok(r,'the list has a rail')
// The pages' capsule takes the column's foot (ui/pages.js, tools/e2e/pages.cjs): Back heads the rail; Search is beside the title.
assert.deepEqual(ids(r),['back'])
for(const i of r.items){assert.ok(i.x>=376&&i.x+i.w<=466,'in the system column '+i.id+' '+JSON.stringify(i));assert.ok(i.w>=44&&i.h>=44,'44pt '+i.id)}
// Centred under the status bar's clock, 49pt in from the edge as measured on device — whatever inset the outer
// display reports (~91pt; the rail stood 9pt left of the clock when it was taken from the inset).
const inset=await D.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue('--wide-inset-right'))
for(const i of r.items)assert.ok(Math.abs(i.x+i.w/2-(466-49))<=1,`under the clock ${i.id} at ${i.x+i.w/2} (inset ${inset})`)
await D.evaluate(()=>document.documentElement.style.setProperty('--wide-inset-right','91px'));await sleep(200)
for(const i of (await rail(D,'.pane-list > .duo-rail')).items)assert.ok(Math.abs(i.x+i.w/2-(466-49))<=1,'still under the clock with a 91pt inset '+JSON.stringify(i))
assert.ok(r.items[0].y>=170-.5,'below the camera and status bar, clear of the signal ring with Silent mode on (158pt)')
// Search stands beside the title instead (blue glass, as tall as it), New chat in Home's rail.
const find=await D.evaluate(()=>{const s=document.querySelector('.pane-list .list-search').getBoundingClientRect(),t=document.querySelector('.pane-list .large-title').getBoundingClientRect();return{h:Math.round(s.height),th:Math.round(t.height),top:Math.round(s.top-t.top)}})
assert.deepEqual(find,{h:find.th,th:find.th,top:0},'Search beside the title, as tall as it')
// …and the pages' capsule below the rail, at the column's foot, clear of it.
const pagesTop=await D.evaluate(()=>document.querySelector('.page-rail').getBoundingClientRect().top)
assert.ok(r.items[0].y+r.items[0].h<pagesTop,'the pages below '+pagesTop)
assert.equal(await D.locator('.pane-list .list-bottombar .bar-item').count(),0,'nothing in the bar at the foot')
const rowsRight=await D.evaluate(()=>Math.max(...[...document.querySelectorAll('.pane-list .row-inner')].map(e=>e.getBoundingClientRect().right)))
assert.ok(rowsRight<=376+.5,'rows stop at the column: '+rowsRight)
await D.screenshot({path:path.join(OUT,'76-rail-list.png')})

// 2. Search is a button; the field opens above the list, Cancel takes the head of the rail.
await D.locator('.pane-list .list-search').tap();await sleep(500)
assert.equal(await D.evaluate(()=>document.activeElement===document.querySelector('.pane-list .search-pill input')),true,'the field has focus')
assert.ok((await D.locator('.pane-list .search-pill').boundingBox()).y<100,'the field is above the list')
r=await rail(D,'.pane-list > .duo-rail');assert.deepEqual(ids(r),['cancel'])
await D.screenshot({path:path.join(OUT,'77-rail-search.png')})
await D.locator('.pane-list .duo-rail [data-item="cancel"]').tap();await sleep(500)
assert.deepEqual(ids(await rail(D,'.pane-list > .duo-rail')),['back'],'back to the rail it was')
assert.equal(await D.locator('.pane-list').evaluate(e=>e.classList.contains('searching')||e.classList.contains('search-open')),false)

// 3. The conversation: Back, the calls, the details; the field and the heading keep to the content.
await open(D)
r=await rail(D,'.thread:not([hidden]) > .duo-rail');assert.deepEqual(ids(r),['back','audio','video','info'])
for(const i of r.items){assert.ok(i.x>=376&&i.x+i.w<=466,'in the column '+i.id);assert.ok(i.w>=44&&i.h>=44)}
for(let i=1;i<r.items.length;i++)assert.ok(r.items[i].y>=r.items[i-1].y+r.items[i-1].h-.5,r.items[i].id+' under '+r.items[i-1].id)
const geo=await D.evaluate(()=>{const q=s=>document.querySelector('.thread:not([hidden]) '+s).getBoundingClientRect();return{field:q('.composer .field').right,action:q('.composer-action').right,title:q('.thread-title').right,nav:q('.thread-nav').right}})
for(const [k,v] of Object.entries(geo))assert.ok(v<=376+.5,k+' stops at the column: '+v)
assert.equal(await D.locator('.thread:not([hidden]) .thread-nav .bar-item').count(),0,'nothing in the heading')
assert.equal(await D.locator('.thread:not([hidden]) .composer .bar-item').count(),0,'nothing in the bar at the foot but the field and its button')
await D.screenshot({path:path.join(OUT,'78-rail-thread.png')})
// A call from the rail reaches the call.
// The details open in place of the conversation, with Back in the rail.
await D.locator('.thread:not([hidden]) .duo-rail [data-item="info"]').tap();await sleep(800)
r=await rail(D,'.art-body > .duo-rail');assert.ok(r&&ids(r).length===1&&['back','close'].includes(ids(r)[0]),'details: '+JSON.stringify(r&&ids(r)))
await D.screenshot({path:path.join(OUT,'79-rail-details.png')})
await D.locator('.art-body .duo-rail .bar-item').first().tap();await sleep(800)
assert.ok(await rail(D,'.thread:not([hidden]) > .duo-rail'),'back to the conversation')

// 4. The drawing board: Close and Send at the head of the rail, Undo and Clear at its foot.
await D.locator('.thread:not([hidden]) .composer .composer-action').tap();await sleep(500)
await D.locator('button:has-text("手绘"), [data-tool="draw"]').first().tap();await D.locator('.draw').waitFor();await sleep(700)
const draw=await D.evaluate(()=>{const q=s=>{const e=document.querySelector(s).getBoundingClientRect();return{x:e.x,y:e.y,r:e.right,b:e.bottom,w:e.width,h:e.height}};return{close:q('.draw-close'),send:q('.draw-send'),tools:q('.draw-tools'),stage:q('.draw-stage'),palette:q('.draw-palette')}})
for(const k of['close','send','tools'])assert.ok(draw[k].x>=376&&draw[k].r<=466,k+' in the column '+JSON.stringify(draw[k]))
assert.ok(draw.close.w>=44&&draw.send.w>=44&&draw.close.y<draw.send.y&&draw.send.b<draw.tools.y,'Close, Send, then Undo and Clear at the foot')
assert.ok(draw.stage.r<=376+.5&&draw.palette.r<=376+.5,'the paper and the colours stop at the column')
await D.screenshot({path:path.join(OUT,'80-rail-draw.png')})
await D.locator('.draw-close').tap();await sleep(700)

// 5. The sidebar: Search and New Chat.
await D.locator('.thread:not([hidden]) .duo-rail [data-item="back"]').tap();await sleep(700)
await D.locator('.pane-list .duo-rail [data-item="back"]').tap();await sleep(800)
r=await rail(D,'.pane-sidebar > .duo-rail');assert.ok(r,'the sidebar has a rail');assert.deepEqual(ids(r),['search','compose'])
await D.screenshot({path:path.join(OUT,'81-rail-sidebar.png')})

// 6. An ordinary phone: no column, no rail — the bars at the foot of each column.
assert.equal(await axis(P),'horizontal')
assert.equal(await rail(P,'.pane-list > .duo-rail'),null,'no rail')
assert.ok(await P.locator('.pane-list .list-bottombar .bar-item').count()>=1,'the list keeps its bar')
await open(P)
assert.equal(await rail(P,'.thread:not([hidden]) > .duo-rail'),null)
assert.ok(await P.locator('.thread:not([hidden]) .composer .bar-item[data-item="back"]').count(),'Back leads the bar at the foot')
assert.ok(await P.locator('.thread:not([hidden]) .thread-nav .bar-item[data-item="info"]').count(),'the details in the heading')
await P.screenshot({path:path.join(OUT,'82-phone-bars.png')})

// 7. Unfolded Duo: the list beside the conversation keeps its bar; the conversation, in the column, has the rail.
assert.equal(await axis(U),'vertical')
await open(U)
assert.equal(await rail(U,'.pane-list > .duo-rail'),null,'the leading list keeps its bar')
assert.ok(await U.locator('.pane-list .list-bottombar .bar-item').count()>=1)
r=await rail(U,'.thread:not([hidden]) > .duo-rail');assert.ok(r);assert.deepEqual(ids(r),['audio','video','info'],'no Back beside the list')
for(const i of r.items)assert.ok(Math.abs(i.x+i.w/2-(890-49))<=1,'open, under the clock too '+JSON.stringify(i))
for(const i of r.items)assert.ok(i.x>=890-84-.5,'in the system column '+i.id)
await U.screenshot({path:path.join(OUT,'83-rail-unfolded.png')})
await U.locator('.thread:not([hidden]) .duo-rail [data-item="info"]').tap();await sleep(900)
assert.ok(await rail(U,'.art-body > .duo-rail'),'the details column has the rail')
assert.equal(await rail(U,'.thread:not([hidden]) > .duo-rail'),null,'and the conversation beside it, now leading, has its bar')
assert.ok(await U.locator('.thread:not([hidden]) .composer .bar-item[data-item="back"], .thread:not([hidden]) .thread-nav .bar-item').count())
await U.screenshot({path:path.join(OUT,'84-rail-unfolded-details.png')})

// 8. They follow the window: the system column goes (as when leaving the Duo's full screen), and the bars are at the foot.
await D.locator('.pane-sidebar .duo-rail').waitFor({state:'attached'})
await D.locator('.pane-sidebar .duo-rail [data-item="compose"]').focus()
await D.evaluate(()=>document.documentElement.style.setProperty('--wide-inset-right','0px'));await sleep(500)
assert.equal(await axis(D),'horizontal','no column, no rail')
assert.equal(await rail(D,'.pane-sidebar > .duo-rail'),null)
assert.equal(await D.evaluate(()=>document.activeElement?.dataset?.item),'compose','focus stays on the item as it moves')
assert.ok(await D.locator('.pane-sidebar .side-bottombar .bar-item').count()>=2,'Search and New Chat at the foot')
await D.evaluate(()=>document.documentElement.style.setProperty('--wide-inset-right','90px'));await sleep(500)
assert.equal(await axis(D),'vertical');assert.ok(await rail(D,'.pane-sidebar > .duo-rail'),'and the column is back')

assert.deepEqual(errors,[])
console.log('PASS: with the system column on the right edge (the Duo full screen) the controls stand in it as a rail — list: Back, with Search beside the title (it opens its field above the list, Cancel at the head); conversation: Back, calls, details, with the heading and the field stopping at the column; details: Back; drawing board: Close, Send, Undo and Clear; sidebar: Search and New Chat — and rows and content stop at the column; an ordinary phone has no rail, the bars stay at the foot; unfolded, the leading column keeps its bar and the trailing one has the rail; they follow the column as it goes and returns, focus kept')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
