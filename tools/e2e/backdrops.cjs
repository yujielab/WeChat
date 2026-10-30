// The conversation list: holding a row (or a pinned one, or a right click) opens its menu — read/unread,
// pin, mute, delete — in place of the swipe to the right; a swipe to the left still shows Delete and, all the
// way across, deletes. Swipes are real touches: a row follows the finger and settles from wherever it is;
// a tap on it, another row, a vertical drag, Escape or a gesture the system takes over puts it back, never
// deleting; Delete is drawn only as wide as it is uncovered. A deleted conversation comes back with the next
// message. Then backdrops: for every conversation, for one, for calls, and a profile's cover (presets and
// photos), kept on the server and the same on each device. npm run dev:e2e; node tools/e2e/backdrops.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-backdrops')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const uniq=Date.now().toString(36)

;(async()=>{const browser=await chromium.launch();try{
const errors=[]
async function page(display,{touch=false}={}){
  const ctx=await browser.newContext({viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:2,hasTouch:touch})
  const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${display}] ${e.message}`));p.setDefaultTimeout(10000)
  await p.goto(BASE);return p
}
async function account(username,display,opts){
  const p=await page(display,opts)
  const status=await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username,password:'hunter22',display})
  assert.equal(status,200,'registered '+username)
  await p.reload();await p.waitForSelector('.shell')
  return p
}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
const A=await account(`ka_${uniq}`,'小明',{touch:true}),B=await account(`kb_${uniq}`,'小红'),C=await account(`kc_${uniq}`,'小刚')
const rb=(await api(A,'/api/dm',{username:`kb_${uniq}`})).room.id,rc=(await api(A,'/api/dm',{username:`kc_${uniq}`})).room.id
await api(C,'/api/messages',{room:rc,type:'text',text:'周末去爬山吗'})
await api(B,'/api/messages',{room:rb,type:'text',text:'晚上一起吃饭'})
await A.reload();await A.waitForSelector(`.row[data-id="${rb}"]`);await A.waitForSelector(`.row[data-id="${rc}"]`)
await A.evaluate(([rb,rc])=>Promise.all([rb,rc].map(id=>fetch(`/api/room/${id}/read`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({ts:Date.now()})}))),[rb,rc])
await A.reload();await A.waitForSelector(`.row[data-id="${rb}"]`)

// Real touches through the browser: it decides what is a scroll (pan-y) and what is the row's.
const cdp=await A.context().newCDPSession(A)
const touch=(type,x,y)=>cdp.send('Input.dispatchTouchEvent',{type,touchPoints:type==='touchEnd'||type==='touchCancel'?[]:[{x,y,id:1}]})
const centre=async id=>{const b=await A.locator(`.row[data-id="${id}"] .row-inner`).boundingBox();return{x:b.x+b.width/2,y:b.y+b.height/2}}
async function drag(id,dx,{dy=0,steps=10,end='touchEnd',from}={}){
  const{x,y}=from||await centre(id)
  await touch('touchStart',x,y)
  for(let i=1;i<=steps;i++){await touch('touchMove',x+dx*i/steps,y+dy*i/steps);await sleep(16)}
  await touch(end,x+dx,y+dy)
}
const tap=async id=>{const{x,y}=await centre(id);await touch('touchStart',x,y);await sleep(40);await touch('touchEnd',x,y)}
const holdRow=async id=>{const{x,y}=await centre(id);await touch('touchStart',x,y);await sleep(650);await touch('touchEnd',x,y)}
const rowX=id=>A.evaluate(id=>document.querySelector(`.row[data-id="${id}"]`)?._x||0,id)
const opened=()=>A.evaluate(async()=>(await import('/js/store.js')).state.open)
const settled=()=>sleep(650)

// 1. Nothing on the leading side any more; Delete alone on the trailing side, not drawn at rest.
const shape=await A.evaluate(()=>[...document.querySelectorAll('.rows > .row')].map(r=>({sides:r.querySelectorAll('.row-actions').length,buttons:[...r.querySelectorAll('.row-action')].map(b=>b.textContent.trim()),width:r.querySelector('.row-actions').getBoundingClientRect().width,shown:getComputedStyle(r.querySelector('.row-actions')).visibility})))
assert.deepEqual(shape,[{sides:1,buttons:['删除'],width:0,shown:'hidden'},{sides:1,buttons:['删除'],width:0,shown:'hidden'}])

// 2. A swipe to the right on a closed row moves nothing (and opens nothing).
await drag(rb,140);await settled()
assert.equal(await rowX(rb),0,'nothing to reveal on the leading side');assert.equal(await opened(),null)

// 3. A short swipe left opens Delete: exactly as wide as what is uncovered, starting at the row's edge.
await drag(rb,-70);await settled()
assert.equal(Math.round(await rowX(rb)),-78,'opens to Delete')
const geo=await A.evaluate(id=>{const r=document.querySelector(`.row[data-id="${id}"]`),a=r.querySelector('.row-actions').getBoundingClientRect(),i=r.querySelector('.row-inner').getBoundingClientRect(),o=r.getBoundingClientRect();return{actionsLeft:a.left,innerRight:i.right,actionsRight:a.right,rowRight:o.right,width:a.width}},rb)
assert.ok(Math.abs(geo.actionsLeft-geo.innerRight)<1.5&&Math.abs(geo.actionsRight-geo.rowRight)<1.5&&Math.abs(geo.width-78)<1.5,'Delete fills only the uncovered part '+JSON.stringify(geo))
await A.screenshot({path:path.join(OUT,'52-swipe-delete.png')})

// 4. A tap on the open row closes it and opens nothing.
await tap(rb);await settled()
assert.equal(await rowX(rb),0,'the tap put it back');assert.equal(await opened(),null,'and opened nothing')

// 5. Open one, touch another: the first goes back, the second doesn't open.
await drag(rb,-70);await settled();await tap(rc);await settled()
assert.equal(await rowX(rb),0);assert.equal(await opened(),null)

// 6. A vertical drag on an open row puts it back (and is left to scrolling).
await drag(rb,-70);await settled();await drag(rb,0,{dy:60});await settled()
assert.equal(await rowX(rb),0,'a scroll closes it')

// 7. Escape puts it back.
await drag(rb,-70);await settled();await A.focus(`.row[data-id="${rb}"] .row-inner`);await A.keyboard.press('Escape');await settled()
assert.equal(await rowX(rb),0,'Escape closes it')

// 8. Caught mid-flight: a touch while it settles stops it where it is; letting go settles it from there.
await drag(rb,-70,{steps:3});await sleep(30)
let{x,y}=await centre(rb);await touch('touchStart',x,y);await sleep(60)
const caught=await rowX(rb)
assert.ok(caught<-0.5&&caught>-77.5,'held where the touch caught it: '+caught)
await sleep(100);assert.equal(await rowX(rb),caught,'and stays there under the finger')
await touch('touchEnd',x,y);await settled()
assert.ok([0,-78].includes(Math.round(await rowX(rb))),'then settles to a rest')
if(Math.round(await rowX(rb))!==0){await tap(rb);await settled()}

// 9. A gesture the system takes over, past the point of deleting: nothing is deleted, the row settles.
await drag(rb,-330,{end:'touchCancel'});await settled()
assert.ok(await A.locator(`.row[data-id="${rb}"]`).count(),'still there');assert.equal(Math.round(await rowX(rb)),-78,'settled open')
await tap(rb);await settled()

// 10. Hold: its menu, and the conversation stays closed.
await holdRow(rb);await A.locator('.menu.on').waitFor()
assert.deepEqual(await A.locator('.menu.on .menu-item .label').allTextContents(),['标为未读','置顶','消息免打扰','删除聊天'])
assert.equal(await opened(),null,'holding opened nothing')
await A.screenshot({path:path.join(OUT,'53-row-menu.png')})
await A.locator('.menu.on .menu-item:has-text("置顶")').click();await sleep(500)
assert.ok(await A.locator(`.pin[data-id="${rb}"]`).count(),'pinned')
// A pinned one has the same menu, held or right-clicked.
await A.locator(`.pin[data-id="${rb}"]`).click({button:'right'});await A.locator('.menu.on').waitFor()
await A.locator('.menu.on .menu-item:has-text("取消置顶")').click();await sleep(500)
assert.equal(await A.locator(`.pin[data-id="${rb}"]`).count(),0,'unpinned')

// 11. Marked unread by hand: counted, kept by the server, cleared by reading.
await A.locator(`.row[data-id="${rb}"] .row-inner`).click({button:'right'});await A.locator('.menu.on .menu-item:has-text("标为未读")').click();await sleep(500)
const count=()=>A.evaluate(id=>{const c=document.querySelector(`.row[data-id="${id}"] .row-count`);return c.hidden?0:Number(c.textContent)},rb)
assert.equal(await count(),1)
await A.reload();await A.waitForSelector(`.row[data-id="${rb}"]`);assert.equal(await count(),1,'kept after a reload')
await A.locator(`.row[data-id="${rb}"] .row-inner`).click({button:'right'});await A.locator('.menu.on .menu-item:has-text("标为已读")').click();await sleep(500)
assert.equal(await count(),0)

// 12. Mute from the menu, and back.
await A.locator(`.row[data-id="${rc}"] .row-inner`).click({button:'right'});await A.locator('.menu.on .menu-item:has-text("消息免打扰")').click();await sleep(400)
assert.ok(await A.locator(`.row.muted[data-id="${rc}"]`).count())
await A.locator(`.row[data-id="${rc}"] .row-inner`).click({button:'right'});await A.locator('.menu.on .menu-item:has-text("取消免打扰")').click();await sleep(400)
assert.equal(await A.locator(`.row.muted[data-id="${rc}"]`).count(),0)

// 13. All the way across deletes; the server keeps it deleted; the next message brings it back.
const listed=id=>A.evaluate(async id=>(await (await fetch('/api/rooms')).json()).rooms.some(r=>r.id===id),id)
await drag(rc,-340);await sleep(1000)
assert.equal(await A.locator(`.row[data-id="${rc}"]`).count(),0,'deleted')
for(let i=0;i<30&&await listed(rc);i++)await sleep(100)
await A.reload();await A.waitForSelector(`.row[data-id="${rb}"]`);assert.equal(await A.locator(`.row[data-id="${rc}"]`).count(),0,'still deleted after a reload')
await api(C,'/api/messages',{room:rc,type:'text',text:'还在吗'});await A.waitForSelector(`.row[data-id="${rc}"]`)

// 14. Delete from the menu.
await A.locator(`.row[data-id="${rc}"] .row-inner`).click({button:'right'});await A.locator('.menu.on .menu-item:has-text("删除聊天")').click();await sleep(800)
assert.equal(await A.locator(`.row[data-id="${rc}"]`).count(),0,'deleted from the menu')
await api(C,'/api/messages',{room:rc,type:'text',text:'回来了'});await A.waitForSelector(`.row[data-id="${rc}"]`)

// ------------------------------------------------------------ backdrops
const photo=async(p,colors)=>Buffer.from((await p.evaluate(colors=>{const c=document.createElement('canvas');c.width=60;c.height=90;const g=c.getContext('2d'),gr=g.createLinearGradient(0,0,60,90);colors.forEach((k,i)=>gr.addColorStop(i/(colors.length-1),k));g.fillStyle=gr;g.fillRect(0,0,60,90);return c.toDataURL('image/png')},colors)).split(',')[1],'base64')
const prefs=p=>p.evaluate(async()=>(await import('/js/store.js')).state.prefs)
const closeSheets=async p=>{for(let i=0;i<3&&await p.locator('.sheet').count();i++){await p.keyboard.press('Escape');await sleep(400)}}
const settings=async p=>{await p.evaluate(async()=>(await import('/js/views/sheets.js')).openSettings({onLogout(){}}));await p.locator('.sheet .bd-value').first().waitFor();await sleep(300)}
const pick=async(p,label)=>{await p.locator(`.sheet:last-of-type .bd-tile[aria-label="${label}"]`).click();await sleep(500)}
// A second device on the same account, to see a choice reach it.
const A2=await page('小明·二');await A2.context().addCookies(await A.context().cookies());await A2.reload();await A2.waitForSelector('.shell')

// 15. For every conversation, from Settings: shown at once, the same on the other device, kept after a reload.
await settings(A);await A.locator('.sheet .cell:has-text("聊天背景")').click();await A.locator('.bd-grid').waitFor();await sleep(300)
await A.screenshot({path:path.join(OUT,'54-backdrop-picker.png')})
await pick(A,'朝霞')
assert.equal((await prefs(A)).chat,'preset:dawn')
assert.equal(await A.locator('.sheet:last-of-type .bd-tile[aria-label="朝霞"]').getAttribute('aria-checked'),'true')
for(let i=0;i<20&&(await prefs(A2)).chat!=='preset:dawn';i++)await sleep(100)
assert.equal((await prefs(A2)).chat,'preset:dawn','reached the other device')
await A.keyboard.press('Escape');await sleep(500)
assert.match(await A.locator('.sheet .cell:has-text("聊天背景") .bd-value').textContent(),/朝霞/,'the row in Settings follows')
await closeSheets(A)
await A.locator(`.row[data-id="${rb}"] .row-inner`).click();await A.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(500)
assert.equal(await A.locator('.thread:not([hidden]) .thread-backdrop').getAttribute('data-backdrop'),'dawn')
assert.ok(await A.locator('.thread.has-backdrop:not([hidden])').count())
await A.screenshot({path:path.join(OUT,'55-chat-backdrop.png')})
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('dark'));await sleep(400)
await A.screenshot({path:path.join(OUT,'56-chat-backdrop-dark.png')})
await A.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('light'));await sleep(300)

// 16. One conversation of its own (from its details), others keep the one for all; then a photo of yours.
await A.locator('.thread:not([hidden]) .thread-title').click();await A.locator('.art-body .cell:has-text("聊天背景")').waitFor();await sleep(300)
assert.match(await A.locator('.art-body .cell:has-text("聊天背景") .bd-value').textContent(),/跟随通用/)
await A.locator('.art-body .cell:has-text("聊天背景")').click();await A.locator('.bd-grid').waitFor();await sleep(300)
await pick(A,'深海')
assert.deepEqual((await prefs(A)).rooms,{[rb]:'preset:ocean'})
assert.equal(await A.locator('.thread:not([hidden]) .thread-backdrop').getAttribute('data-backdrop'),'ocean')
await A.locator('.sheet:last-of-type .bd-grid input[type=file]').setInputFiles({name:'bg.png',mimeType:'image/png',buffer:await photo(A,['#f6a','#6af'])})
for(let i=0;i<40&&!/^\/api\/media\/bg\//.test((await prefs(A)).rooms[rb]||'');i++)await sleep(100)
assert.match((await prefs(A)).rooms[rb],/^\/api\/media\/bg\//,'a photo of yours')
await A.waitForFunction(()=>document.querySelector('.thread:not([hidden]) .thread-backdrop')?.dataset.backdrop==='photo')
await closeSheets(A);await sleep(300)
await A.screenshot({path:path.join(OUT,'57-chat-photo-backdrop.png')})
await A.reload();await A.waitForSelector(`.row[data-id="${rc}"]`);await sleep(800)
if(await opened()){await A.locator('.thread:not([hidden]) [data-item="back"]').click();await sleep(600)}
await A.locator(`.row[data-id="${rc}"] .row-inner`).click();await A.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(500)
assert.equal(await A.locator('.thread:not([hidden]) .thread-backdrop').getAttribute('data-backdrop'),'dawn','the others keep the one for all')

// 17. Calls: chosen in Settings, behind the call screen (always its dark drawing).
await settings(A);await A.locator('.sheet .cell:has-text("通话背景")').click();await A.locator('.bd-grid').waitFor();await sleep(300)
await pick(A,'星夜');assert.equal((await prefs(A)).call,'preset:night');await closeSheets(A)
await A.evaluate(async([rb,peer])=>{const{state}=await import('/js/store.js'),{createCalls}=await import('/js/views/call.js');state.calls={...state.calls,enabled:true};window.testCalls=createCalls({socketSend(){},connected:()=>true});window.testCalls.onSignal({t:'call',kind:'invite',room:rb,callId:'bd1',media:'audio',from:peer,caller:{id:peer,display:'小红'}})},[rb,(await B.evaluate(async()=>(await import('/js/store.js')).state.me.id))])
await A.locator('.call .call-backdrop[data-backdrop="night"]').waitFor()
await sleep(500);await A.screenshot({path:path.join(OUT,'58-call-backdrop.png')})
await A.evaluate(()=>document.querySelector('.call .call-btn.hang')?.click());await A.locator('.call').waitFor({state:'detached'}).catch(()=>{})

// 18. A profile's cover: a preset, then a photo; on your card at once, and in your profile for the others.
await settings(A);await A.locator('.sheet .profile-btn').click();await A.locator('.cover-edit').waitFor();await sleep(300)
await A.locator('.cover-edit').click();await A.locator('.bd-grid').waitFor();await sleep(300)
await pick(A,'薄荷')
assert.equal(await A.evaluate(async()=>(await import('/js/store.js')).state.me.cover),'preset:mint')
assert.equal(await A.locator('.cover-edit .backdrop').getAttribute('data-backdrop'),'mint')
await A.locator('.sheet:last-of-type .bd-grid input[type=file]').setInputFiles({name:'cover.png',mimeType:'image/png',buffer:await photo(A,['#2c7','#fd4','#e45'])})
for(let i=0;i<40&&!/^\/api\/media\/cover\//.test(await A.evaluate(async()=>(await import('/js/store.js')).state.me.cover));i++)await sleep(100)
await A.keyboard.press('Escape');await sleep(500)
await A.waitForFunction(()=>document.querySelector('.cover-edit .backdrop')?.dataset.backdrop==='photo')
await A.screenshot({path:path.join(OUT,'59-cover-edit.png')})
await A.keyboard.press('Escape');await sleep(500)
assert.ok(await A.locator('.sheet .profile-btn.has-cover .profile-cover').count(),'on your card at once')
await closeSheets(A)
await B.reload();await B.waitForSelector(`.row[data-id="${rb}"]`);await B.locator(`.row[data-id="${rb}"] .row-inner`).click();await B.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(400)
await B.locator('.thread:not([hidden]) .thread-title').click();await B.locator('.art-body .profile.has-cover').waitFor()
await B.waitForFunction(()=>document.querySelector('.art-body .profile-cover')?.dataset.backdrop==='photo')
assert.equal(await B.locator('.thread:not([hidden]) .thread-backdrop').getAttribute('data-backdrop'),'','someone else\'s backdrops are theirs alone')
await sleep(300);await B.screenshot({path:path.join(OUT,'60-peer-cover.png')})

assert.deepEqual(errors,[])
console.log('PASS: list rows have no leading actions — holding a row or a pinned one (or a right click) opens read/unread, pin, mute and delete; a swipe left shows Delete drawn only as wide as it is uncovered; real touches: right swipe on a closed row does nothing, a tap on the open row or on another row, a vertical drag and Escape put it back and open nothing, a touch catches it mid-flight, a cancelled gesture never deletes, all the way across deletes; marked unread is kept by the server and cleared by reading; a deleted conversation comes back with the next message. Backdrops for every conversation, for one, for calls and a profile cover, presets and photos, kept on the server and the same on another device; others see the cover, never the backdrops')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
