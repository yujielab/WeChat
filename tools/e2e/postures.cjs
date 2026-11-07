// The Duo's three postures and the moves between them (js/ui/viewport.js →
// data-pose; js/ui/columns.js and js/ui/strip.js; css/posture.css):
//   closed — the outer display: one column.
//   half   — partly open like a book: two columns meeting the hinge, a soft
//            shade gathered either side of it; like a laptop: the
//            conversation (or a call, or a photo) above the hinge, the field
//            and the controls below.
//   open   — flat: the conversation wide, the list or the details narrow.
// Half ↔ open glides the divider on a spring with the hinge's gap closing or
// opening, overlays gliding with it; standing up or laying flat morphs; and
// through all of it the message being read, the draft, the caret and focus
// stay put. Registers two users against a local dev server.
// npm run dev:e2e; node tools/e2e/postures.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-postures')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms)),uniq=Math.random().toString(36).slice(2,7)
const INNER={width:951,height:669},OUTER={width:466,height:678},UPRIGHT={width:669,height:951}

;(async()=>{const browser=await chromium.launch();const errors=[];try{
async function account(u,d,opts){const ctx=await browser.newContext({locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:2,...opts});const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${d}] ${e.message}`));p.setDefaultTimeout(10000);await p.goto(BASE);assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username:u,password:'hunter22',display:d}),200);await p.reload();await p.waitForSelector('.shell');return p}
const api=(p,url,body)=>p.evaluate(async([url,body])=>(await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)})).json(),[url,body])
const B=await account(`qb_${uniq}`,'小红',{viewport:OUTER})
const A=await account(`qa_${uniq}`,'TOKIO',{viewport:INNER,isMobile:true,hasTouch:true})
const room=(await api(A,'/api/dm',{username:`qb_${uniq}`})).room.id
const lines=['在吗','周末一起去爬山吗？天气预报说周六晴天，不太热，适合出门走走，我们可以早点出发，中午在山顶吃饭','好呀，几点出发？','早上八点在地铁站见','要带什么吗','水和一点吃的就够了，山上有小卖部但是很贵','好的👍','对了，要不要叫上小明','可以啊，他上次说也想去','那我问问他']
for(let i=0;i<24;i++)await api(i%2?A:B,'/api/messages',{room,type:'text',text:`${lines[i%lines.length]}（${i+1}）`})
await A.reload();await A.waitForSelector('.row');await sleep(600)
await A.locator('.row .row-inner').first().click();await A.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(900)

// The page allows no eval: a change is named, with its argument.
const vp=(fn,arg=null)=>A.evaluate(async([fn,arg])=>{const v=await import('/js/ui/viewport.js');v[fn](arg)},[fn,arg])
const cols=()=>A.evaluate(()=>Object.fromEntries([...document.querySelectorAll('.pane:not(.off)')].map(p=>{const r=p.getBoundingClientRect();return[p.dataset.col,{x:Math.round(r.x*10)/10,w:Math.round(r.width*10)/10}]})))
const pose=()=>A.evaluate(()=>document.documentElement.dataset.pose)
const gutter=()=>A.evaluate(()=>Number(getComputedStyle(document.querySelector('.shell'),'::after').opacity))
// Samples the divider (the conversation's left edge) every frame while fn runs.
const sampleDivider=([fn,arg],ms=900)=>A.evaluate(async([fn,arg,ms])=>{const v=await import('/js/ui/viewport.js');const pane=document.querySelector('.pane[data-col="thread"]');const out=[];const t0=performance.now();v[fn](arg);await new Promise(done=>{const tick=()=>{const r=pane.getBoundingClientRect();out.push({t:performance.now()-t0,x:r.x,w:r.width});if(performance.now()-t0<ms)requestAnimationFrame(tick);else done()};requestAnimationFrame(tick)});return out},[fn,arg,ms])

// 1. Open flat: the list narrow, the conversation wide; no hinge, no shade.
assert.equal(await pose(),'open')
let c=await cols()
assert.deepEqual(c.list,{x:0,w:342},'the list, narrow '+JSON.stringify(c));assert.deepEqual(c.thread,{x:342,w:609},'the conversation, wide')
assert.equal(await gutter(),0)
await A.screenshot({path:path.join(OUT,'1-open-flat.png')})

// The reading place, the draft, the caret and focus, to keep through every change below.
await A.evaluate(()=>{const s=document.querySelector('.thread:not([hidden]) .thread-scroll');s.scrollTop=-260})
await sleep(300)
const reading=()=>A.evaluate(()=>{const s=document.querySelector('.thread:not([hidden]) .thread-scroll'),top=s.getBoundingClientRect().top+90;const m=[...s.querySelectorAll('.m[data-id]')].find(m=>m.getBoundingClientRect().bottom>top);return{id:m?.dataset.id,y:Math.round(m?.getBoundingClientRect().top)}})
const before=await reading()
await A.locator('.thread:not([hidden]) .composer textarea').click();await A.keyboard.type('我们八点见，');await A.evaluate(()=>{const t=document.querySelector('.thread:not([hidden]) .composer textarea');t.setSelectionRange(2,2)})
const held=()=>A.evaluate(()=>{const t=document.querySelector('.thread:not([hidden]) .composer textarea');return{value:t.value,caret:t.selectionStart,focused:document.activeElement===t}})
const draft=await held()

// 2. Half open (a book): the divider glides to the hinge on a spring while the gap opens; the shade gathers.
const glide=await sampleDivider(['emulateFold',{axis:'vertical',size:28}])
const xs=glide.map(s=>s.x)
assert.ok(xs.some(x=>x>360&&x<470),'it passes through the places between, not a jump '+JSON.stringify(xs.map(Math.round)))
const reached=glide.find(s=>Math.abs(s.x-490)<1);assert.ok(reached&&reached.t>150&&reached.t<800,'and arrives in a few hundred milliseconds '+JSON.stringify(reached))
assert.ok(Math.max(...xs)<=490+12,'a spring settles, it does not fling '+Math.max(...xs))
assert.equal(await pose(),'half')
c=await cols();assert.deepEqual(c.list,{x:0,w:462});assert.deepEqual(c.thread,{x:490,w:461},'each meets the hinge, nothing in the bend')
assert.equal(await gutter(),1,'the hinge\'s shade')
await A.screenshot({path:path.join(OUT,'2-half-book.png')})
let now=await reading();assert.equal(now.id,before.id,'the same message is being read');assert.ok(Math.abs(now.y-before.y)<=40,'near where it was '+JSON.stringify([before,now]))
assert.deepEqual(await held(),draft,'the draft, the caret and focus stay')

// 3. Opening flat again: back to the conversation's own width, the shade fading.
const back=await sampleDivider(['emulateFold',null])
assert.ok(back.some(s=>s.x>350&&s.x<480),'it glides back '+JSON.stringify(back.map(s=>Math.round(s.x))))
c=await cols();assert.deepEqual(c.thread,{x:342,w:609});assert.equal(await pose(),'open')
now=await reading();assert.equal(now.id,before.id);assert.deepEqual(await held(),draft)

// 4. A device that only says it is folded (no segments): the hinge down the middle.
await vp('emulatePosture','folded');await sleep(900)
c=await cols();assert.equal(await pose(),'half');assert.deepEqual(c.list,{x:0,w:475.5});assert.deepEqual(c.thread,{x:475.5,w:475.5})
await vp('emulatePosture',null);await sleep(900)

// 5. Open flat, the details come in narrow and the conversation slides over at its own width — not one line reflows.
const bubble=()=>A.evaluate(()=>[...document.querySelectorAll('.thread:not([hidden]) .bubble')].map(b=>Math.round(b.getBoundingClientRect().height)).join(','))
const shape=await bubble()
const widths=await A.evaluate(async()=>{const pane=document.querySelector('.pane[data-col="thread"]');const out=[];document.querySelector('.thread:not([hidden]) [data-item="info"]').click();const t0=performance.now();await new Promise(done=>{const tick=()=>{out.push(Math.round(pane.getBoundingClientRect().width));if(performance.now()-t0<700)requestAnimationFrame(tick);else done()};requestAnimationFrame(tick)});return out})
assert.ok(widths.every(w=>w===609),'the conversation stays 609 wide the whole way '+[...new Set(widths)])
c=await cols();assert.deepEqual(c.thread,{x:0,w:609});assert.deepEqual(c.artifact,{x:609,w:342})
assert.equal(await bubble(),shape,'no message changed shape')
await A.screenshot({path:path.join(OUT,'3-open-details.png')})
await A.keyboard.press('Escape');await sleep(700)

// 6. A sheet half open keeps to its side of the hinge; opening flat it glides to the middle with the divider.
await vp('emulateFold',{axis:'vertical',size:28});await sleep(900)
await A.evaluate(async()=>{const{openSettings}=await import('/js/views/sheets.js');openSettings({onLogout(){},origin:null})});await A.locator('.sheet.on').waitFor();await sleep(700)
let s=await A.locator('.sheet').boundingBox()
assert.ok(s.x>=490,'half open, on its column\'s side '+JSON.stringify(s))
await A.screenshot({path:path.join(OUT,'4-half-sheet.png')})
const lefts=await A.evaluate(async()=>{const v=await import('/js/ui/viewport.js');const el=document.querySelector('.sheet');const out=[];v.emulateFold(null);const t0=performance.now();await new Promise(done=>{const tick=()=>{out.push(Math.round(el.getBoundingClientRect().x));if(performance.now()-t0<800)requestAnimationFrame(tick);else done()};requestAnimationFrame(tick)});return out})
assert.ok(lefts.some(x=>x<s.x-20&&x>216+10),'it glides across '+JSON.stringify(lefts))
s=await A.locator('.sheet').boundingBox();assert.ok(Math.abs(s.x+s.width/2-INNER.width/2)<=1,'open flat, in the middle of the screen '+JSON.stringify(s))
await A.keyboard.press('Escape');await A.locator('.sheet').waitFor({state:'detached'})

// 7. Reduced motion: the divider is simply there.
await A.emulateMedia({reducedMotion:'reduce'})
const still=await sampleDivider(['emulateFold',{axis:'vertical',size:28}],300)
assert.ok(still.every(x=>Math.abs(x.x-490)<1||Math.abs(x.x-342)<1)&&Math.abs(still.at(-1).x-490)<1,'no glide with reduced motion: there, with nothing between '+JSON.stringify(still.map(s=>Math.round(s.x))))
await vp('emulateFold',null);await sleep(200);await A.emulateMedia({reducedMotion:'no-preference'})

// 8. Upright, flat: one column, still "open". Stood up like a laptop: the messages above the hinge, the field
// below, morphing there; the hinge shaded.
await A.setViewportSize(UPRIGHT);await sleep(900)
assert.equal(await pose(),'open');c=await cols();assert.deepEqual(Object.keys(c),['thread'])
const turned=await A.evaluate(async()=>{const v=await import('/js/ui/viewport.js');v.emulateFold({axis:'horizontal',size:28});return document.documentElement.dataset.poseTurn!==undefined})
assert.ok(turned,'standing up morphs (a view transition)')
await sleep(900)
assert.equal(await A.evaluate(()=>document.documentElement.dataset.poseTurn),undefined,'and lets go when done')
assert.equal(await pose(),'half')
const halves=await A.evaluate(()=>{const fs=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--fold-start')),fe=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--fold-end'));const sc=document.querySelector('.thread:not([hidden]) .thread-scroll').getBoundingClientRect(),co=document.querySelector('.thread:not([hidden]) .composer').getBoundingClientRect();return{fs,fe,scrollBottom:sc.bottom,composerTop:co.top}})
assert.ok(halves.scrollBottom<=halves.fs+1&&halves.composerTop>=halves.fe-1,'messages above, the field below '+JSON.stringify(halves))
const shade=await A.evaluate(()=>{const c=getComputedStyle(document.querySelector('.shell'),'::after');return{o:c.opacity,top:parseFloat(c.top),h:parseFloat(c.height),l:c.left,r:c.right}})
assert.ok(shade.o==='1'&&shade.h<120&&Math.abs(shade.top+26-halves.fs)<2,'the hinge shaded across '+JSON.stringify(shade))
await A.screenshot({path:path.join(OUT,'5-tabletop.png')})
// A photo, looked at above the hinge.
await A.evaluate(async()=>{const c=document.createElement('canvas');c.width=800;c.height=600;const g=c.getContext('2d');g.fillStyle='#4a7';g.fillRect(0,0,800,600);g.fillStyle='#fff';g.fillRect(300,200,200,200);const{openViewer}=await import('/js/views/viewer.js');openViewer({src:c.toDataURL(),w:800,h:600})})
await sleep(900)
const photo=await A.evaluate(()=>{const fs=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--fold-start'));const st=document.querySelector('.viewer-stage').getBoundingClientRect(),m=document.querySelector('.viewer-media').getBoundingClientRect();return{fs,stageBottom:st.bottom,mediaBottom:m.bottom,mediaTop:m.top}})
assert.ok(photo.stageBottom<=photo.fs+1&&photo.mediaBottom<=photo.fs+1,'the photo above the hinge '+JSON.stringify(photo))
const closeAt=await A.locator('.viewer [aria-label="关闭"]').boundingBox()
assert.ok(closeAt.y>=photo.fs,'Close under the hand, below the hinge '+JSON.stringify(closeAt))
await A.screenshot({path:path.join(OUT,'6-tabletop-photo.png')})
await A.keyboard.press('Escape');await sleep(600)
// Laid flat again: the usual layout returns.
await vp('emulateFold',null);await sleep(900);assert.equal(await pose(),'open')

// 9. Closed: the outer display, one column.
await A.setViewportSize(OUTER);await sleep(900)
assert.equal(await pose(),'closed');c=await cols();assert.equal(Object.keys(c).length,1);assert.equal(c.thread.w,466)
assert.deepEqual(await held(),draft,'the draft survives closing too')

// 10. A call stood up like a laptop: their picture above the hinge, the controls on the half lying flat; it moves there
// as the screen is stood up. (Browser-only fixtures, as in call-avatar.cjs: the call service is stubbed to wait.)
{
  const json=body=>({contentType:'application/json',body:JSON.stringify(body)})
  const ctx=await browser.newContext({viewport:UPRIGHT,serviceWorkers:'block',locale:'zh-CN',deviceScaleFactor:2,permissions:['microphone','camera']})
  const q=await ctx.newPage();q.on('pageerror',e=>errors.push('[call] '+e.message));q.setDefaultTimeout(8000)
  await q.route('**/auth/status',r=>r.fulfill(json({authed:false})));await q.route('**/api/**',r=>r.fulfill(json({ok:true})))
  await q.route('**/rtc/**',async r=>{await sleep(6000);r.fulfill({status:503,...json({ok:false,error:'test'})})})
  await q.goto(BASE);await q.locator('.auth').waitFor()
  await q.evaluate(async()=>{const{state}=await import('/js/store.js'),{createCalls}=await import('/js/views/call.js');state.me={id:'me',display:'我'};state.calls={enabled:true};state.chats=new Map([['r',{id:'r',kind:'dm',room:false,name:'小红',peer:{id:'p',display:'小红'},unread:0}]]);window.calls=createCalls({socketSend:()=>{},connected:()=>true})})
  await q.evaluate(()=>window.calls.onSignal({t:'call',kind:'invite',room:'r',callId:'c1',media:'video',from:'p',caller:{id:'p',display:'小红'}}));await sleep(600)
  await q.evaluate(async()=>(await import('/js/ui/viewport.js')).emulateFold({axis:'horizontal',size:28}));await sleep(900)
  const call=await q.evaluate(()=>{const v=n=>parseFloat(getComputedStyle(document.documentElement).getPropertyValue(n));const st=document.querySelector('.call-stage').getBoundingClientRect(),ctl=document.querySelector('.call-incoming:not([hidden]), .call-controls:not([hidden])').getBoundingClientRect();return{fs:v('--fold-start'),fe:v('--fold-end'),stageBottom:st.bottom,controlsTop:ctl.top,controlsBottom:ctl.bottom}})
  assert.ok(call.stageBottom<=call.fs+1&&call.controlsTop>=call.fe-1,'the picture above the hinge, the controls below it '+JSON.stringify(call))
  await q.screenshot({path:path.join(OUT,'7-tabletop-call.png')})
  await q.evaluate(()=>document.querySelector('.call .call-btn.hang')?.click());await ctx.close()
}

// 11. What a real browser does: it changes its segments or its posture without a word to the page (no event, the
// viewport keeps its size). The page still follows, within a moment. With segments, two that touch (a continuous
// folding screen, no gap) are half open — they were taken for no hinge, which left the Duo stuck open with the
// Viewport Segments API on; and with segments to go by, the posture doesn't decide. Without them, the posture does.
{
  const cookies=await A.context().cookies()
  const silent=async(init,label)=>{
    const ctx=await browser.newContext({viewport:INNER,locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:1,isMobile:true,hasTouch:true})
    await ctx.addCookies(cookies);await ctx.addInitScript(init)
    const q=await ctx.newPage();q.on('pageerror',e=>errors.push(`[${label}] `+e.message));await q.goto(BASE);await q.waitForSelector('.shell');await sleep(600)
    return q
  }
  const state=q=>q.evaluate(()=>{const r=p=>document.querySelector(`.pane[data-col="${p}"]`)?.getBoundingClientRect();return{pose:document.documentElement.dataset.pose,list:Math.round(r('list').width),thread:Math.round(r('thread').width)}})
  const waitPose=async(q,want)=>{for(let i=0;i<20;i++){if((await state(q)).pose===want)return true;await sleep(50)}return false}
  // The Viewport Segments API, reporting through window.viewport.segments only, quietly.
  const withSegments=()=>{window.__seg=[{x:0,y:0,width:innerWidth,height:innerHeight}];Object.defineProperty(window,'viewport',{configurable:true,value:{get segments(){return window.__seg}}});Object.defineProperty(navigator,'devicePosture',{configurable:true,value:{type:'folded',addEventListener(){}}})}
  let q=await silent(withSegments,'segments')
  assert.equal((await state(q)).pose,'open','one segment: open, though the posture says folded')
  await q.evaluate(()=>{window.__seg=[{x:0,y:0,width:476,height:innerHeight},{x:476,y:0,width:innerWidth-476,height:innerHeight}]})
  const t0=Date.now();assert.ok(await waitPose(q,'half'),'two touching segments, no event: half open '+JSON.stringify(await state(q)));const took=Date.now()-t0
  assert.ok(took<700,'within a moment: '+took+'ms');await sleep(800)
  let st=await state(q);assert.ok(st.pose==='half'&&st.list===476&&Math.abs(st.list+st.thread-INNER.width)<=1,'the columns meet at the hinge '+JSON.stringify(st))
  assert.deepEqual(await q.evaluate(async()=>{const r=(await import('/js/ui/viewport.js')).getPostureReadings();return{pose:r.pose,source:r.source,segments:r.segments?.length,fold:[r.fold.start,r.fold.end],posture:r.posture}}),{pose:'half',source:'segments',segments:2,fold:[476,476],posture:'folded'},'what the device reports')
  await q.evaluate(()=>{window.__seg=[{x:0,y:0,width:innerWidth,height:innerHeight}]})
  assert.ok(await waitPose(q,'open'),'and back to one segment: open');await sleep(800)
  assert.deepEqual(await state(q),{pose:'open',list:342,thread:609})
  await q.context().close()
  // No segments API at all (the flag off): the posture decides, also when it changes without an event.
  const postureOnly=()=>{window.__pos='continuous';Object.defineProperty(window,'viewport',{configurable:true,value:undefined});const mm=window.matchMedia.bind(window);window.matchMedia=query=>/viewport-segments/.test(query)?{matches:false,media:query,addEventListener(){},removeEventListener(){}}:mm(query);Object.defineProperty(navigator,'devicePosture',{configurable:true,value:{get type(){return window.__pos},addEventListener(){}}})}
  q=await silent(postureOnly,'posture')
  assert.equal((await state(q)).pose,'open')
  await q.evaluate(()=>{window.__pos='folded'});assert.ok(await waitPose(q,'half'),'folded, no event: half open');await sleep(800)
  st=await state(q);assert.ok(st.pose==='half'&&st.list===476&&Math.abs(st.list+st.thread-INNER.width)<=1,'down the middle '+JSON.stringify(st))
  await q.evaluate(()=>{window.__pos='continuous'});assert.ok(await waitPose(q,'open'),'continuous again: open, not stuck half')
  await q.context().close()
}

assert.deepEqual(errors,[],'no page errors')
console.log('PASS: open flat — list 342 | conversation 609, no shade; half open — the divider glides on a spring to the hinge (462 | 28 | 461) with the gap opening and a shade gathering, and back; a device that only says "folded" — the middle; the message being read, the draft, the caret and focus kept through it all; open flat the details come in narrow while the conversation keeps its 609 (no message reflows); a sheet on its side when half open glides to the middle when opened flat; reduced motion — no glide; upright — one column, open; stood like a laptop — a morph to messages above and the field below the hinge, shaded, a photo above it with Close below; a call stood up — their picture above, the controls below; closed — one column; segments or a posture changing without an event are followed within a moment, two touching segments are half open, one segment is open whatever the posture says, and without segments the posture decides both ways; Settings shows what the device reports')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
