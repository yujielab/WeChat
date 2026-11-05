// Your routine and habits in the memory sheet (views/memory.js, src/routine.js). First as a long-known routine
// (the server's answer stood in for: two weeks of use), to see all of it — when you are usually up, the day hour by
// hour with the quiet hours shaded and this hour marked, your busiest hours, how you answer, what you send, your
// emoji, who you talk to when — light and dark. Then for real, against the local server with real accounts: a
// day's use shows up, the switch turns learning off (asking first) and forgets it, and on again starts afresh.
// npm run dev:e2e; node tools/e2e/routine.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-routine')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const uniq=Date.now().toString(36)
const json=body=>({contentType:'application/json',body:JSON.stringify(body)})
const openSheet=p=>p.evaluate(async()=>{const{openMemorySheet}=await import('/js/views/memory.js');openMemorySheet(null)})
const closeSheets=async p=>{await p.evaluate(async()=>(await import('/js/views/overlay.js')).closeAllOverlays());await sleep(400)}

;(async()=>{const browser=await chromium.launch();try{
const errors=[]

// 1. Two weeks known.
const hours=[.2,0,0,0,0,0,0,.9,.5,.4,.45,.4,.5,.6,.35,.45,.4,.5,.55,.6,.8,1,.85,.5]
const ROUTINE={learning:true,days:14,confidence:'high',wake:460,sleep:30,weekday:null,weekend:null,hours,peak:[20,23],quiet:[1,7],reply:42,length:6,
  kinds:[{kind:'text',share:78},{kind:'sticker',share:15},{kind:'image',share:7}],emoji:['😂','👍','🙏'],peers:[{band:'morning',name:'妈妈'},{band:'evening',name:'小红'}]}
const F=await browser.newPage({viewport:{width:466,height:678},serviceWorkers:'block',locale:'zh-CN',deviceScaleFactor:2})
F.on('pageerror',e=>errors.push('[fixture] '+e.message));F.setDefaultTimeout(8000)
await F.route('**/auth/status',r=>r.fulfill(json({authed:false})));await F.route('**/api/**',r=>r.fulfill(json({ok:true,messages:[]})))
let learn=true
await F.route('**/api/ai/memory',r=>r.fulfill(json({ok:true,confidence:'medium',style:{words:['材料','电脑'],endings:['明天见'],messages:42,at:Date.now()},digests:[],routine:learn?ROUTINE:{...ROUTINE,learning:false,days:0}})))
await F.route('**/api/ai/memory/routine',async r=>{learn=r.request().postDataJSON().learn;r.fulfill(json({ok:true,routine:learn?{...ROUTINE,days:0,confidence:'none',wake:null,sleep:null,peak:null,quiet:null,reply:null,length:null,kinds:[],emoji:[],peers:[]}:{...ROUTINE,learning:false,days:0}}))})
await F.goto(BASE);await F.locator('.auth').waitFor()
await openSheet(F);await F.locator('.routine-chart').waitFor();await sleep(500)
const shown=await F.evaluate(()=>({
  heads:[...document.querySelectorAll('.memory-sheet .memory-head > span:first-child')].map(e=>e.textContent),
  note:document.querySelector('.memory-sheet .memory-head .memory-note')?.textContent,
  line:document.querySelector('.routine-line')?.textContent,
  bars:document.querySelectorAll('.routine-bar').length,
  quiet:[...document.querySelectorAll('.routine-bar')].map((b,i)=>b.classList.contains('quiet')?i:-1).filter(i=>i>=0),
  now:[...document.querySelectorAll('.routine-bar')].findIndex(b=>b.classList.contains('now')),
  hour:new Date().getHours(),
  tallest:[...document.querySelectorAll('.routine-bar')].map(b=>b.getBoundingClientRect().height),
  notes:[...document.querySelectorAll('.routine-note')].map(e=>e.textContent),
  rows:Object.fromEntries([...document.querySelectorAll('.memory-row')].map(r=>[r.querySelector('.memory-row-label').textContent,r.querySelector('.memory-row-value').textContent])),
  label:document.querySelector('.routine-chart').getAttribute('aria-label'),
  sw:document.querySelector('.memory-switch .switch')?.getAttribute('aria-checked')
}))
assert.deepEqual(shown.heads.slice(0,2),['作息','习惯'],'the routine comes first, then the habits')
assert.equal(shown.note,'已经熟悉 · 14 天')
assert.equal(shown.line,'通常 7:40 起来、0:30 睡')
assert.equal(shown.bars,24)
assert.deepEqual(shown.quiet,[1,2,3,4,5,6],'the quiet hours shaded')
assert.equal(shown.now,shown.hour,'this hour marked')
assert.equal(shown.tallest.indexOf(Math.max(...shown.tallest)),21,'the busiest hour the tallest')
assert.deepEqual(shown.notes,['最常在 20–23 点 · 1–7 点 很少上线'])
assert.deepEqual(shown.rows,{'回复':'通常 1 分钟内','消息':'多是短句，大约 6 个字','常发':'文字 78% · 表情 15% · 图片 7%','常用表情':'😂 👍 🙏','时段':'早上常和 妈妈 · 晚上常和 小红'})
assert.match(shown.label,/一天中各个小时的活跃程度，最常在 20–23 点，1–7 点 很少上线/,'the chart is described for VoiceOver')
assert.equal(shown.sw,'true')
await F.screenshot({path:path.join(OUT,'87-routine-sheet.png')})
await F.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('dark'));await sleep(400)
await F.screenshot({path:path.join(OUT,'88-routine-sheet-dark.png')})
await F.evaluate(async()=>(await import('/js/ui/appearance.js')).setTheme('light'));await sleep(200)
// Turning it off asks first; cancelling keeps it on.
await F.locator('.memory-switch .switch').click();await F.locator('.menu.on').waitFor();await F.keyboard.press('Escape');await sleep(300)
assert.equal(await F.locator('.memory-switch .switch').getAttribute('aria-checked'),'true','cancelled: still on')
assert.equal(learn,true)
await F.locator('.memory-switch .switch').click();await F.locator('.menu.on .menu-item',{hasText:'关闭'}).click();await sleep(500)
assert.equal(learn,false,'asked the server to stop')
assert.equal(await F.locator('.memory-switch .switch').getAttribute('aria-checked'),'false')
assert.match(await F.locator('.memory-sheet').textContent(),/学习已关闭/)
assert.equal(await F.locator('.routine-chart').count(),0,'nothing of it shown')
await F.screenshot({path:path.join(OUT,'89-routine-off.png')})
await F.close()

// 2. For real: a day's use.
async function account(username,display){
  const ctx=await browser.newContext({viewport:{width:466,height:678},locale:'zh-CN',serviceWorkers:'block',deviceScaleFactor:2,timezoneId:'Asia/Shanghai'})
  const p=await ctx.newPage();p.on('pageerror',e=>errors.push(`[${display}] ${e.message}`));p.setDefaultTimeout(10000)
  await p.goto(BASE)
  assert.equal(await p.evaluate(async b=>(await fetch('/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)})).status,{username,password:'hunter22',display}),200)
  await p.reload();await p.waitForSelector('.shell')
  return p
}
const api=(p,url,body)=>p.evaluate(async([url,body])=>{const{api}=await import('/js/api.js');return api.post(url,body)},[url,body])
const A=await account(`ra_${uniq}`,'小明'),B=await account(`rb_${uniq}`,'小红')
const room=(await api(A,'/api/dm',{username:`rb_${uniq}`})).room.id
await api(B,'/api/messages',{room,type:'text',text:'在吗？'})
for(const text of['在的😂','好的👍','明天见👍'])await api(A,'/api/messages',{room,type:'text',text})
await openSheet(A);await A.locator('.memory-switch').waitFor();await sleep(400)
const real=await A.evaluate(()=>({note:document.querySelector('.memory-head .memory-note')?.textContent,bars:document.querySelectorAll('.routine-bar').length,rows:Object.fromEntries([...document.querySelectorAll('.memory-row')].map(r=>[r.querySelector('.memory-row-label').textContent,r.querySelector('.memory-row-value').textContent])),more:[...document.querySelectorAll('.routine-note')].map(e=>e.textContent)}))
assert.equal(real.note,'还在了解你 · 1 天','one day seen')
assert.equal(real.bars,24)
assert.equal(real.rows['常用表情'],'👍 😂','the emoji from what was sent')
assert.equal(real.rows['常发'],'文字 100%')
assert.ok(real.more.includes('再用几天会更准。'))
assert.equal(await A.locator('.routine-line').count(),0,'a few minutes are not "usually": no waking or sleeping time yet')
assert.ok(!/null|undefined/.test(await A.locator('.memory-sheet').textContent()),'nothing missing is written out')
await A.screenshot({path:path.join(OUT,'90-routine-first-day.png')})
// Off, and the server forgets; reopened, still off; on again, afresh.
await A.locator('.memory-switch .switch').click();await A.locator('.menu.on .menu-item',{hasText:'关闭'}).click();await sleep(600)
const off=await A.evaluate(async()=>{const{api}=await import('/js/api.js');return(await api.get('/api/ai/memory')).routine})
assert.equal(off.learning,false);assert.equal(off.days,0);assert.deepEqual(off.emoji,[])
await api(A,'/api/messages',{room,type:'text',text:'关掉以后😅'})
assert.equal((await A.evaluate(async()=>{const{api}=await import('/js/api.js');return(await api.get('/api/ai/memory')).routine})).days,0,'nothing learned while off')
await closeSheets(A);await openSheet(A);await A.locator('.memory-switch').waitFor();await sleep(300)
assert.equal(await A.locator('.memory-switch .switch').getAttribute('aria-checked'),'false','reopened: still off')
await A.locator('.memory-switch .switch').click();await sleep(600)
assert.equal(await A.locator('.memory-switch .switch').getAttribute('aria-checked'),'true')
await api(A,'/api/messages',{room,type:'text',text:'又开了'})
const again=await A.evaluate(async()=>{const{api}=await import('/js/api.js');return(await api.get('/api/ai/memory')).routine})
assert.equal(again.learning,true);assert.equal(again.days,1);assert.deepEqual(again.emoji,[],'afresh: what was forgotten stays forgotten')

assert.deepEqual(errors,[])
console.log('PASS: the memory sheet shows the routine (usual waking and sleeping, the day hour by hour with quiet hours shaded and this hour marked, the busiest hours, described for VoiceOver) and the habits (how soon and how long you answer, what you send, your emoji, who you talk to when), light and dark; turning learning off asks first, forgets and stops learning, and stays off; on again starts afresh; for real, a day of use shows up with its emoji')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
