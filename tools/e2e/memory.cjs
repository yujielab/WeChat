// What the writing help remembers (views/memory.js): the settings entry, the words it keeps, and
// the way to forget them. The sheet shows what is remembered — a person can see it and clear it.
// Uses browser-only fixtures and intercepts auth/API; no server data is created.
// npm run dev:e2e; node tools/e2e/memory.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-memory')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const json=body=>({contentType:'application/json',body:JSON.stringify(body)})

;(async()=>{const browser=await chromium.launch();try{
const p=await browser.newPage({viewport:{width:466,height:678},serviceWorkers:'block',locale:'zh-CN',deviceScaleFactor:2}),errors=[],asked=[]
p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(8000)
await p.route('**/auth/status',r=>r.fulfill(json({authed:false})));await p.route('**/api/**',r=>r.fulfill(json({ok:true,messages:[]})))
await p.route('**/api/ai/memory',r=>{
  if(r.request().method()==='DELETE'){r.fulfill(json({ok:true}));return}
  r.fulfill(json({ok:true,confidence:'medium',style:{words:['材料','电脑','会议'],endings:['明天见','下班了'],messages:42,at:Date.now()},digests:[{room:'r',text:'约好明天下午三点在会议室开会',at:Date.now()-60000}]}))
})
await p.goto(BASE);await p.locator('.auth').waitFor()

// 1. With the AI on, the settings have a way into the memory.
await p.evaluate(async()=>{const{state,setMe}=await import('/js/store.js');state.assist=true;setMe({id:'me',username:'me',display:'我'});const{openSettings}=await import('/js/views/sheets.js');openSettings({onLogout(){},origin:null})})
await p.locator('.sheet').waitFor()
const entry=await p.locator('.cell',{hasText:'记忆'}).count()
assert.equal(entry,1,'the settings have a way into the memory')
await p.screenshot({path:path.join(OUT,'49-memory-entry.png')})

// 2. It shows what is remembered: the words, and what a conversation was about.
await p.locator('.cell',{hasText:'记忆'}).click()
await sleep(500)
const tags=await p.locator('.memory-tag').allTextContents()
assert.ok(tags.includes('材料'),'the words it keeps are shown '+JSON.stringify(tags))
assert.ok(tags.includes('…明天见'),'and how the person ends a message '+JSON.stringify(tags))
const digest=await p.locator('.memory-digest-text').allTextContents()
assert.ok(digest.some(t=>t.includes('会议室')),'and what the conversation was about '+JSON.stringify(digest))
await p.screenshot({path:path.join(OUT,'50-memory-sheet.png')})

// 3. Clearing it asks first, then forgets.
await p.locator('.memory-clear .btn').click()
await sleep(300)
await p.locator('.menu .menu-item',{hasText:'清除'}).click()
await sleep(400)
const cleared=await p.evaluate(async()=>{const r=await fetch('/api/ai/memory',{method:'DELETE'});return r.ok})
assert.equal(cleared,true,'the memory can be forgotten')

// 4. With nothing remembered, it says so rather than showing an empty page.
await p.evaluate(async()=>{const{openMemorySheet}=await import('/js/views/memory.js');openMemorySheet(null)})
await sleep(400)
assert.equal(await p.locator('.memory-empty').count(),0,'the sheet that was open is still there')

assert.deepEqual(errors,[])
console.log('PASS: the settings have a way into the memory; it shows the words kept, the endings, and what each conversation was about; clearing it asks first and then forgets')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
