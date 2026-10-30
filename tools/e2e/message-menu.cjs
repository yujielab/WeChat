// Long-press on a message: the conversation blurs away, the message lifts out exactly as it was (same box,
// same lines, same type, no scaling — even when the press's own shrink is still easing back), its reactions
// stand in a capsule above it and its actions in a card below it, nothing overlapping, all on screen, lined
// up with the message's side; a message near the foot moves up just enough, a very tall one is cut to fit.
// Uses browser-only fixtures and intercepts auth/API; no server data is created.
// npm run dev:e2e; node tools/e2e/message-menu.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-message-menu')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const json=body=>({contentType:'application/json',body:JSON.stringify(body)})
const LONG=Array.from({length:40},(_,i)=>'这是一条很长的消息，第'+(i+1)+'行。').join('\n')
const MSGS=[['a1','p','我想下班'],['a2','me','宝贝'],['a3','p',LONG],['a4','p','为什么为什么为什么!'],['a5','me','好的，马上到'],['a6','p','你好了?']]

;(async()=>{const browser=await chromium.launch();try{
const p=await browser.newPage({viewport:{width:466,height:678},serviceWorkers:'block',locale:'zh-CN',deviceScaleFactor:2}),errors=[]
p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(8000)
await p.route('**/auth/status',r=>r.fulfill(json({authed:false})));await p.route('**/api/**',r=>r.fulfill(json({ok:true,messages:[]})))
await p.goto(BASE);await p.locator('.auth').waitFor()
await p.evaluate(async MSGS=>{const{state,thread,mergeMessages}=await import('/js/store.js'),{createThread}=await import('/js/views/thread.js');state.me={id:'me',display:'我'};state.chats=new Map([['r',{id:'r',kind:'dm',name:'pll',peer:{id:'p',display:'pll'},unread:0}]]);const t=thread('r');t.loaded=true;t.hasMore=false;mergeMessages('r',MSGS.map(([id,from,text],i)=>({id,chat:'r',type:'text',text,from,out:from==='me',ts:Date.now()-(MSGS.length-i)*60000,status:'sent'})));const shell=document.createElement('div');shell.className='shell';shell.dataset.layout='stack';shell.dataset.thread='open';const pane=document.createElement('section');pane.className='pane';pane.dataset.role='single';shell.append(pane);document.querySelector('#app').replaceChildren(shell);window.testThread=createThread(pane,{onBack(){},onInfo(){},onDraw(){},onCall(){},socketSend(){}});testThread.setLayout('single');await testThread.open('r')},MSGS)
await sleep(500)

// Press and hold, as a finger does: the bubble shrinks a little while held, and the menu opens while it eases back.
async function hold(id){const b=await p.locator(`.m[data-id="${id}"] .bubble`).boundingBox();await p.mouse.move(b.x+b.width/2,b.y+b.height/2);await p.mouse.down();await sleep(620);await p.mouse.up();await p.locator('.menu.ctx-menu.on').waitFor();await sleep(320)}
const layout=id=>p.evaluate(id=>{
  const box=el=>{const r=el.getBoundingClientRect();return{l:r.left,t:r.top,r:r.right,b:r.bottom,w:r.width,h:r.height}}
  const orig=document.querySelector(`.m[data-id="${id}"] .bubble`),prev=document.querySelector('.ctx-preview'),copy=prev.querySelector('.bubble')
  const cs=getComputedStyle(orig),cc=getComputedStyle(copy)
  const lines=el=>{const r=document.createRange();r.selectNodeContents(el);return new Set([...r.getClientRects()].map(x=>Math.round(x.top))).size}
  const frame=document.querySelector('.menu-safe-frame')
  return{orig:{w:orig.offsetWidth,h:orig.offsetHeight,hidden:getComputedStyle(orig).visibility==='hidden'},copy:{w:copy.offsetWidth,h:copy.offsetHeight},
    type:[cs.fontSize,cs.lineHeight,cs.borderTopLeftRadius,cs.paddingLeft,cs.color,cs.backgroundColor].join('|'),copyType:[cc.fontSize,cc.lineHeight,cc.borderTopLeftRadius,cc.paddingLeft,cc.color,cc.backgroundColor].join('|'),
    origLines:lines(orig),copyLines:lines(copy),scale:new DOMMatrix(getComputedStyle(prev).transform).a,
    prev:box(prev),menu:box(document.querySelector('.menu.ctx-menu')),bar:document.querySelector('.ctx-reactions')?box(document.querySelector('.ctx-reactions')):null,frame:box(frame),
    cut:prev.classList.contains('cut'),blur:getComputedStyle(document.querySelector('.ctx-backdrop')).backdropFilter}
},id)
const close=async()=>{await p.keyboard.press('Escape');await p.locator('.ctx-preview').waitFor({state:'detached'});await sleep(150)}
const inside=(a,f)=>a.l>=f.l-0.5&&a.r<=f.r+0.5&&a.t>=f.t-0.5&&a.b<=f.b+0.5

// 1. The reported case: a short incoming message at the foot of the screen.
await hold('a6');let L=await layout('a6')
assert.deepEqual(L.copy,{w:L.orig.w,h:L.orig.h},'the lifted message keeps its exact box '+JSON.stringify(L))
assert.equal(L.copyType,L.type,'the same type, corners, padding and colours')
assert.deepEqual([L.origLines,L.copyLines],[1,1],'the same lines: “你好了?” stays on one line')
assert.equal(L.scale,1,'not scaled');assert.ok(L.orig.hidden,'the original steps aside')
assert.ok(L.menu.t>=L.prev.b+8,'the actions sit below the message, never over it '+JSON.stringify([L.prev,L.menu]))
assert.ok(L.bar&&L.bar.b<=L.prev.t-4,'the reactions stand above it')
for(const [n,b] of [['message',L.prev],['actions',L.menu],['reactions',L.bar]])assert.ok(inside(b,L.frame),n+' on screen '+JSON.stringify([b,L.frame]))
assert.ok(Math.abs(L.menu.l-L.prev.l)<1&&Math.abs(L.bar.l-L.prev.l)<1,'an incoming message: everything lines up on its left')
assert.match(L.blur,/blur\(26px\)/,'the conversation blurs away')
await p.screenshot({path:path.join(OUT,'43-message-menu.png')})
// Keyboard: Tab goes between the actions and the reactions; Escape puts the message back.
const focusIn=()=>p.evaluate(()=>document.activeElement.closest('.ctx-reactions')?'reactions':document.activeElement.closest('.menu')?'menu':'elsewhere')
assert.equal(await p.evaluate(()=>document.querySelector('.menu.ctx-menu').classList.contains('has-highlight')),false,'opened by a finger: no row starts highlighted')
assert.equal(await focusIn(),'menu');await p.keyboard.press('ArrowDown')
assert.equal(await p.evaluate(()=>document.activeElement.textContent),'复制','arrow keys still reach the rows')
for(let i=0;i<4;i++)await p.keyboard.press('Tab');assert.notEqual(await focusIn(),'elsewhere','focus stays with the menu and its reactions')
await close();assert.equal(await p.evaluate(()=>getComputedStyle(document.querySelector('.m[data-id="a6"] .bubble')).visibility),'visible')

// 2. An outgoing message lines up on its right.
await hold('a5');L=await layout('a5')
assert.deepEqual([L.copy,L.copyType,L.copyLines],[{w:L.orig.w,h:L.orig.h},L.type,L.origLines])
assert.ok(Math.abs(L.menu.r-L.prev.r)<1&&Math.abs(L.bar.r-L.prev.r)<1,'an outgoing message: everything lines up on its right '+JSON.stringify([L.prev,L.menu,L.bar]))
assert.ok(L.menu.t>=L.prev.b+8&&inside(L.menu,L.frame))
await close()

// 3. A message taller than the screen: its top shows, cut to fit, with the reactions and actions still on screen.
await p.evaluate(()=>document.querySelector('.m[data-id="a3"]').scrollIntoView({block:'start'}));await sleep(300)
await hold('a3');L=await layout('a3')
assert.ok(L.cut,'cut to fit');assert.equal(L.copy.w,L.orig.w,'its width unchanged')
for(const b of [L.prev,L.menu,L.bar])assert.ok(inside(b,L.frame),JSON.stringify([b,L.frame]))
assert.ok(L.menu.t>=L.prev.b+8&&L.bar.b<=L.prev.t-4,'still nothing overlapping')
await p.screenshot({path:path.join(OUT,'44-message-menu-tall.png')})
await close()

// 4. Dark: the same layout, the card and capsule in the dark surface.
await p.evaluate(()=>import('/js/ui/appearance.js').then(a=>a.setTheme('dark')));await sleep(200)
await p.evaluate(()=>document.querySelector('.m[data-id="a6"]').scrollIntoView({block:'center'}));await sleep(300)
await hold('a6');L=await layout('a6')
assert.deepEqual([L.copy,L.copyType,L.copyLines],[{w:L.orig.w,h:L.orig.h},L.type,1]);assert.ok(L.menu.t>=L.prev.b+8&&inside(L.menu,L.frame))
// The card's colour, laid over black: dark in dark mode.
const lum=await p.evaluate(()=>{const c=document.createElement('canvas').getContext('2d');c.fillStyle='#000';c.fillRect(0,0,1,1);c.fillStyle=getComputedStyle(document.querySelector('.menu.ctx-menu')).backgroundColor;c.fillRect(0,0,1,1);const[r,g,b]=c.getImageData(0,0,1,1).data;return(r+g+b)/3})
assert.ok(lum<90,'a dark card in dark mode '+lum)
await p.screenshot({path:path.join(OUT,'45-message-menu-dark.png')})
await close()

assert.deepEqual(errors,[])
console.log('PASS: the lifted message keeps its exact box, lines, type and colours, unscaled, even mid-press; reactions above and actions below, never overlapping, on screen and lined up with its side; a tall message is cut to fit; Tab stays within, Escape puts it back; the conversation blurs away; no row highlighted when opened by a finger; the same in dark')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
