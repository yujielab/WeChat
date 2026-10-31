// Touch always reaches what's on screen. Real touches (CDP) on the folded outer screen:
// 1. swiping back from a conversation leaves the list reachable (it used to stay inert: nothing on it answered);
// 2. a back swipe the system takes over (touchcancel) slides back to the conversation, still reachable;
// 3. a sheet and a menu closed together (closeAllOverlays, as opening a conversation does) leave the app reachable
//    (a menu still fading used to keep the app inert for good);
// 4. a pinned conversation held for its menu opens on the very next tap (that tap used to be swallowed);
// 5. whatever else is left behind — a column made unreachable, a scrim without its sheet — is put right by the touch
//    that finds it, so the next one lands.
// npm run dev:e2e; node tools/e2e/touch.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-touch')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const uniq=Date.now().toString(36)

;(async()=>{const browser=await chromium.launch();try{
const errors=[]
const ctx=await browser.newContext({viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:2,hasTouch:true,isMobile:true})
const p=await ctx.newPage();p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(8000)
await p.goto(BASE)
const reg=async(page,username)=>page.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username,password:'hunter22',display:username})
assert.equal(await reg(p,`ta_${uniq}`),200)
const other=await (await browser.newContext()).newPage();await other.goto(BASE);assert.equal(await reg(other,`tb_${uniq}`),200)
const room=(await p.evaluate(async u=>(await (await fetch('/api/dm',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({username:u})})).json()).room.id,`tb_${uniq}`))
await other.evaluate(async room=>fetch('/api/messages',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({room,type:'text',text:'在吗'})}),room)
await p.reload();await p.waitForSelector(`.row[data-id="${room}"]`)

const cdp=await ctx.newCDPSession(p)
const touch=(type,x,y)=>cdp.send('Input.dispatchTouchEvent',{type,touchPoints:type==='touchEnd'||type==='touchCancel'?[]:[{x,y,id:1}]})
const swipeRight=async({end='touchEnd',to=360}={})=>{await touch('touchStart',60,320);for(let i=1;i<=12;i++){await touch('touchMove',60+i*(to-60)/12,320);await sleep(16)}await touch(end,to,320)}
// Does a tap there reach the element that is drawn there?
const reachable=sel=>p.evaluate(sel=>{const el=document.querySelector(sel);if(!el)return'missing';const r=el.getBoundingClientRect();const hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);return Boolean(hit&&el.contains(hit))&&!el.closest('[inert]')},sel)
const focusCol=()=>p.evaluate(()=>document.querySelector('.shell').dataset.focus)
const openChat=async()=>{await p.tap(`.row[data-id="${room}"] .row-inner`);await p.waitForSelector('.thread:not([hidden]) .msgs .m');await p.waitForFunction(()=>document.querySelector('.shell').dataset.focus==='thread'&&document.querySelector('.shell').dataset.anim===undefined);await sleep(200)}

// 1. Swipe back from the conversation: the list answers again.
await openChat()
await swipeRight();await p.waitForFunction(()=>document.querySelector('.shell').dataset.focus==='list'&&document.querySelector('.shell').dataset.anim===undefined);await sleep(200)
assert.equal(await reachable(`.row[data-id="${room}"] .row-inner`),true,'the list is reachable after a swipe back')
await p.tap(`.row[data-id="${room}"] .row-inner`,{timeout:3000});await p.waitForFunction(()=>document.querySelector('.shell').dataset.focus==='thread')
await sleep(400)

// 2. A swipe the system takes over goes back to the conversation, which still answers.
await swipeRight({end:'touchCancel',to:300});await sleep(700)
assert.equal(await focusCol(),'thread','a cancelled swipe doesn\'t navigate')
assert.equal(await reachable('.thread:not([hidden]) .composer textarea'),true,'the conversation still answers')
assert.equal(await p.evaluate(()=>[...document.querySelectorAll('.pane')].filter(x=>x.dataset.role!=='hidden'&&x.inert).length),0)
await p.locator('.thread:not([hidden]) [data-item="back"]').tap();await p.waitForFunction(()=>document.querySelector('.shell').dataset.focus==='list');await sleep(400)

// 3. A sheet with a menu over it, both closed at once: the app answers again.
await p.evaluate(async()=>{const{openSheet,openMenu,closeAllOverlays}=await import('/js/views/overlay.js');const content=document.createElement('div');content.textContent='面板';openSheet({title:'测试',content});await new Promise(r=>setTimeout(r,300));openMenu({x:100,y:200,w:10,h:10},[[{label:'一项'}]]);await new Promise(r=>setTimeout(r,300));closeAllOverlays()})
await sleep(900)
assert.equal(await p.evaluate(()=>document.getElementById('app').inert),false,'not left inert')
assert.equal(await reachable(`.row[data-id="${room}"] .row-inner`),true)

// 4. Hold a pinned conversation for its menu, close it: the next tap opens the conversation.
await p.evaluate(async id=>{await fetch(`/api/room/${id}/flags`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({pinned:1})});const{patchRoom}=await import('/js/store.js');patchRoom(id,{pinned:true})},room)
await p.waitForSelector(`.pin[data-id="${room}"]`);await sleep(300)
const pin=await p.locator(`.pin[data-id="${room}"]`).boundingBox()
await touch('touchStart',pin.x+pin.width/2,pin.y+pin.height/2);await sleep(650);await touch('touchEnd',pin.x+pin.width/2,pin.y+pin.height/2)
await p.locator('.menu.on').waitFor();await sleep(200);await p.keyboard.press('Escape');await sleep(500)
await p.tap(`.pin[data-id="${room}"]`);await sleep(600)
assert.equal(await focusCol(),'thread','the first tap after the menu opens it')
await p.locator('.thread:not([hidden]) [data-item="back"]').tap();await p.waitForFunction(()=>document.querySelector('.shell').dataset.focus==='list');await sleep(400)

// 5. Left behind by anything else: the touch that finds it puts it right — a column left unreachable answers
// from the next touch on (a touch stays with what it first landed on); a stray scrim is gone at once.
const pinned=`.pin[data-id="${room}"]`
await p.evaluate(()=>{document.querySelector('.pane[data-col="list"]').inert=true})
assert.equal(await reachable(pinned),false,'(made unreachable)')
await p.tap(pinned,{force:true});await sleep(300)
assert.equal(await reachable(pinned),true,'a column left unreachable answers again')
await p.evaluate(()=>{const s=document.createElement('div');s.className='scrim on';document.getElementById('overlays').append(s)})
assert.equal(await reachable(pinned),false,'(covered)')
// A stray scrim is taken away as the touch begins, so that touch goes on to what was under it.
await p.tap(pinned,{force:true});await p.waitForFunction(()=>document.querySelector('.shell').dataset.focus==='thread')
assert.equal(await p.locator('#overlays > .scrim').count(),0,'a scrim without its sheet is taken away')
await p.screenshot({path:path.join(OUT,'73-touch-after-heal.png')})

assert.deepEqual(errors,[])
console.log('PASS: real touches: the list answers after a swipe back; a cancelled swipe slides back and the conversation answers; a sheet and a menu closed together leave the app reachable; a pinned conversation opens on the first tap after its menu; a column left unreachable or a scrim without its sheet is put right by the touch that finds it')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
