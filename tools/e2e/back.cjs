// Back is always in the same place, and stays there. Folded (an ordinary phone, with the bars at each column's
// foot, and the Duo's full screen, with the rail) the button that leads out of a column — Back in the list, the
// conversation and the details, Close on the drawing board — is at one and the same point on every screen, and
// the bars' right-hand ends line up too (New Chat in the list and the sidebar, the field's button). While the
// columns slide, by button or by a finger held half way, each column's Back is carried against its column's
// movement, so on every frame it is exactly where it was and where it will be: one button under the thumb, not two
// sliding past each other. Unfolded there is one way out of a conversation beside its details — their Close —
// and none in the conversation's own bar, which would do the same.
// npm run dev:e2e; node tools/e2e/back.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-back')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const uniq=Date.now().toString(36)
const UA='Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1'
const safeRight84=()=>document.addEventListener('DOMContentLoaded',()=>document.documentElement.style.setProperty('--safe-right','84px'))

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
const phone={viewport:{width:393,height:852},isMobile:true,hasTouch:true}
const duo={viewport:{width:466,height:678},screen:{width:466,height:678},userAgent:UA,isMobile:true,hasTouch:true}
const inner={viewport:{width:890,height:626},isMobile:true,hasTouch:true}

const B=await account(`ka_${uniq}`,'小红',{viewport:{width:466,height:678}})
async function seeded(name,opts,init,n){
  const A=await account(`k${n}_${uniq}`,name,opts,init)
  const room=(await api(A,'/api/dm',{username:`ka_${uniq}`})).room.id
  await api(B,'/api/messages',{room,type:'text',text:'在吗'})
  await A.reload();await A.waitForSelector('.row');await sleep(700)
  return A
}
// Every visible button that leads out of a column, where it is.
const exits=p=>p.evaluate(()=>[...document.querySelectorAll('.bar-item[data-item="back"], .bar-item[data-item="close"], .draw-close')].filter(e=>e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden'&&!e.closest('.pane.off')).map(e=>{const b=e.getBoundingClientRect(),pane=e.closest('.pane');return{what:e.dataset.item||'draw-close',col:pane?.dataset.col||'overlay',x:Math.round(b.x*10)/10,y:Math.round(b.y*10)/10,w:Math.round(b.width)}}))
const open=async p=>{await p.locator('.row .row-inner').first().tap();await p.waitForSelector('.thread:not([hidden]) .msgs .m');await sleep(800)}

for(const [label,opts] of [['an ordinary phone',phone],['the Duo full screen',duo]]){
  const A=await seeded(label,opts,null,label.length)
  const at={}
  // List.
  // On the Duo the controls move into the rail once the system's column is measured, a moment after the list shows.
  await A.waitForFunction(()=>[...document.querySelectorAll('.pane-list .bar-item[data-item="back"]')].some(b=>b.getClientRects().length&&getComputedStyle(b).visibility!=='hidden'));await sleep(200)
  let e=await exits(A);assert.deepEqual(e.map(x=>x.what),['back'],label+': the list has Back');at.list=e[0]
  const listCompose=await A.evaluate(()=>{const b=document.querySelector('.pane-list [data-item="compose"]').getBoundingClientRect();return{right:b.right,bottom:b.bottom}})
  // Conversation.
  await open(A);e=await exits(A);assert.deepEqual(e.map(x=>x.what),['back'],label+': the conversation has Back');at.thread=e[0]
  // The field's button now sits inside the field's end (css/chat.css): the field (or the microphone after it) ends where New Chat does.
  const action=await A.evaluate(()=>{const c=document.querySelector('.thread:not([hidden]) .composer');const ends=[...c.querySelectorAll(':scope > .field, :scope > .composer-mic:not([hidden])')].map(e=>e.getBoundingClientRect().right);return{right:Math.max(...ends)}})
  // Details.
  await A.locator('.thread:not([hidden]) .thread-title').tap();await sleep(900);e=await exits(A);assert.deepEqual(e.map(x=>x.what),['back'],label+': the details have Back');at.details=e[0]
  await A.locator('.art-body [data-item="back"]').tap();await sleep(800)
  // Drawing board.
  await A.locator('.thread:not([hidden]) .composer .composer-action').tap();await sleep(500)
  await A.locator('button:has-text("手绘"), [data-tool="draw"]').first().tap();await A.locator('.draw').waitFor();await sleep(800)
  e=await exits(A);assert.deepEqual(e.map(x=>x.what),['draw-close'],label+': the board has Close');at.draw=e[0]
  await A.locator('.draw-close').tap();await sleep(700)
  for(const k of['thread','details','draw']){assert.ok(Math.abs(at[k].x-at.list.x)<=0.5&&Math.abs(at[k].y-at.list.y)<=0.5&&Math.abs(at[k].w-at.list.w)<=0.5,`${label}: ${k} is where the list's Back is `+JSON.stringify({list:at.list,[k]:at[k]}))}
  if(opts===phone){
    // The right-hand ends of the bars line up: New Chat in the list, the field (with its button inside) in the conversation.
    assert.ok(Math.abs(listCompose.right-action.right)<=0.5,'New Chat and the field share an edge '+JSON.stringify({listCompose,action}))
    await A.locator('.thread:not([hidden]) [data-item="back"]').tap();await sleep(800)
    await A.locator('.pane-list [data-item="back"]').tap();await sleep(800)
    const side=await A.evaluate(()=>{const b=document.querySelector('.pane-sidebar [data-item="compose"]').getBoundingClientRect();return{right:b.right,bottom:b.bottom}})
    assert.ok(Math.abs(side.right-listCompose.right)<=0.5&&Math.abs(side.bottom-listCompose.bottom)<=0.5,'and so does the sidebar\'s '+JSON.stringify({side,listCompose}))
  }
  await A.context().close()
}

// While the columns slide Back doesn't move: sampled on every frame, in both folded modes.
for(const [label,opts] of [['an ordinary phone',phone],['the Duo full screen',duo]]){
  const A=await seeded(label,opts,null,100+label.length)
  await open(A)
  const run=async(what,act)=>{
    await A.evaluate(()=>{window.__s=[];const f=()=>{const row={};for(const k of['sidebar','list','thread','artifact']){const pane=document.querySelector(`.pane[data-col="${k}"]`),b=pane?.querySelector('.bar-item[data-item="back"]');if(b&&!pane.classList.contains('off')){const r=b.getBoundingClientRect(),pr=pane.getBoundingClientRect();row[k]={x:r.x,y:r.y,pane:pr.x}}}window.__s.push(row);if(window.__s.length<70)requestAnimationFrame(f)};requestAnimationFrame(f)})
    await act();await sleep(1000)
    const s=await A.evaluate(()=>window.__s),moved=Math.max(...s.flatMap(r=>Object.values(r).map(c=>Math.abs(c.pane)))),keys=['list','thread','artifact'].filter(k=>s.some(r=>r[k]))
    assert.ok(moved>100,`${label}, ${what}: the columns really slid (${moved})`)
    for(const k of keys){const xs=s.filter(r=>r[k]).map(r=>r[k].x),ys=s.filter(r=>r[k]).map(r=>r[k].y);assert.ok(Math.max(...xs)-Math.min(...xs)<=1&&Math.max(...ys)-Math.min(...ys)<=1,`${label}, ${what}: the ${k}'s Back stays put, x ${Math.min(...xs)}..${Math.max(...xs)}, y ${Math.min(...ys)}..${Math.max(...ys)}`)}
    // Nothing left over once it has settled.
    assert.equal(await A.evaluate(()=>[...document.querySelectorAll('.pane:not(.off) .bar-item[data-item="back"]')].filter(e=>e.style.translate).length),0,`${label}, ${what}: nothing carried at rest`)
  }
  await run('conversation → list',()=>A.locator('.thread:not([hidden]) [data-item="back"]').tap())
  await run('list → conversation',()=>A.locator('.row .row-inner').first().tap())
  await run('conversation → details',()=>A.locator('.thread:not([hidden]) .thread-title').tap())
  await run('details → conversation',()=>A.locator('.art-body [data-item="back"]').first().tap())

  // A finger held half way through the swipe back: the same.
  const cdp=await A.context().newCDPSession(A),touch=(type,x,y)=>cdp.send('Input.dispatchTouchEvent',{type,touchPoints:type==='touchEnd'||type==='touchCancel'?[]:[{x,y,id:1}]})
  const w=opts.viewport.width,before=await exits(A)
  await touch('touchStart',30,300)
  for(const frac of[0.3,0.55,0.8]){
    await touch('touchMove',30+(w-30)*frac,300);await sleep(250)
    const held=await A.evaluate(()=>[...document.querySelectorAll('.pane:not(.off) .bar-item[data-item="back"]')].map(e=>{const b=e.getBoundingClientRect();return{x:b.x,y:b.y}}))
    for(const b of held)assert.ok(Math.abs(b.x-before[0].x)<=1&&Math.abs(b.y-before[0].y)<=1,`${label}: held at ${frac}, Back is where it was `+JSON.stringify({b,was:before[0]}))
    if(frac===0.55)await A.screenshot({path:path.join(OUT,`85-back-held-${label.includes('Duo')?'duo':'phone'}.png`)})
  }
  await touch('touchCancel',0,0);await sleep(900)
  assert.equal(await A.evaluate(()=>[...document.querySelectorAll('.bar-item[data-item="back"]')].filter(e=>e.style.translate).length),0,label+': nothing carried once it springs back')
  await A.context().close()
}

// Unfolded: one way out beside the details; none in a conversation beside the list.
for(const [label,init] of [['unfolded',null],['unfolded on the Duo',safeRight84]]){
  const A=await seeded(label,inner,init,200+label.length)
  await open(A)
  assert.deepEqual((await exits(A)).map(x=>x.what+'@'+x.col),[],label+': beside the list there is no Back')
  await A.locator('.thread:not([hidden]) .thread-title').tap();await sleep(900)
  assert.deepEqual((await exits(A)).map(x=>x.what+'@'+x.col),['close@artifact'],label+': beside the details, their Close is the one way out')
  assert.equal(await A.evaluate(()=>[...document.querySelectorAll('.thread:not([hidden]) .bar-item[data-item="back"]')].filter(e=>e.getClientRects().length).length),0,label+': the conversation has no Back of its own')
  await A.screenshot({path:path.join(OUT,`86-one-way-out-${label.includes('Duo')?'duo':'plain'}.png`)})
  await A.locator('.art-body [data-item="close"]').tap();await sleep(900)
  assert.ok(await A.locator('.pane-list .row').first().isVisible(),'Close brings the list back beside the conversation')
  await A.context().close()
}

assert.deepEqual(errors,[])
console.log('PASS: folded, an ordinary phone and the Duo full screen, the button that leads out of a column is at one point on every screen (list, conversation, details, drawing board) and the bars\' right-hand ends line up; while columns slide by button or by a finger held half way, each column\'s Back stays exactly where it was, every frame, and nothing is left carried at rest; unfolded, a conversation beside its details has no Back of its own — their Close is the one way out — and none beside the list')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
