// Stickers never show empty. Ahead of time (prewarmStickers, after launch) the packs, the opening pack's
// pictures, the add list and the player are fetched, so the panel opens complete; while something is still
// on its way its shape stands in (tabs, grid, add-list rows), and a sticker whose picture is late shows its
// emoji — only after a moment, so a ready one never flickers, with reduced motion too.
// Uses browser-only fixtures and intercepts auth/API; no server data is created.
// npm run dev:e2e; node tools/e2e/stickers.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-stickers')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const PNG=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==','base64')
const LOT=JSON.stringify({v:'5.7.4',fr:30,ip:0,op:30,w:100,h:100,nm:'t',ddd:0,assets:[],layers:[]})
const HAND={name:'HandDrawnEmoji',title:'手绘',stickers:[{id:'AgADstat',emoji:'😀',kind:'static',nt:false},{id:'AgADanim',emoji:'😎',kind:'animated',nt:false}]}
const PACKS=[{name:'HandDrawnEmoji',title:'手绘',count:2,cover:HAND.stickers[0],added:true},{name:'UtyaDuck',title:'小黄鸭',count:1,cover:{id:'AgADduck',emoji:'🦆',kind:'static',nt:false},added:false}]
const json=body=>({contentType:'application/json',body:JSON.stringify(body)})

async function page(browser,{listDelay=0,catalogDelay=0,slow={},gone=[]}={}){
  const p=await browser.newPage({viewport:{width:466,height:678},serviceWorkers:'block',locale:'zh-CN',deviceScaleFactor:2}),errors=[],hits=[]
  p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(8000)
  await p.route('**/auth/status',r=>r.fulfill(json({authed:false})));await p.route('**/api/**',r=>r.fulfill(json({ok:true,messages:[]})))
  await p.route('**/api/stickers',async r=>{hits.push('list');await sleep(listDelay);r.fulfill(json({ok:true,sets:[HAND]}))})
  await p.route('**/api/stickers/catalog',async r=>{hits.push('catalog');await sleep(catalogDelay);r.fulfill(json({ok:true,packs:PACKS}))})
  await p.route('**/api/stickers/img/**',async r=>{const u=new URL(r.request().url()),id=u.pathname.split('/').pop();hits.push('img:'+id+(u.searchParams.has('thumb')?'?thumb':''));await sleep(slow[id]||0);if(gone.includes(id))return r.fulfill({status:404,body:''});r.fulfill({contentType:'image/png',body:PNG})})
  await p.route('**/api/stickers/anim/**',r=>r.fulfill(json(JSON.parse(LOT))))
  await p.goto(BASE);await p.locator('.auth').waitFor()
  await p.evaluate(async()=>{const{state,thread,mergeMessages}=await import('/js/store.js'),{createThread}=await import('/js/views/thread.js');state.me={id:'me',display:'我'};state.stickers=true;state.chats=new Map([['r',{id:'r',kind:'dm',name:'朋友',peer:{id:'p',display:'朋友'},unread:0}]]);const t=thread('r');t.loaded=true;t.hasMore=false;mergeMessages('r',Array.from({length:3},(_,i)=>({id:String(i),chat:'r',type:'text',text:'第'+(i+1)+'条消息',from:'p',out:false,ts:Date.now()-(3-i)*60000,status:'sent'})));const shell=document.createElement('div');shell.className='shell';shell.dataset.layout='stack';shell.dataset.thread='open';const pane=document.createElement('section');pane.className='pane';pane.dataset.role='single';shell.append(pane);document.querySelector('#app').replaceChildren(shell);window.testThread=createThread(pane,{onBack(){},onInfo(){},onDraw(){},onCall(){},socketSend(){}});testThread.setLayout('single');await testThread.open('r')})
  await sleep(300)
  return{p,errors,hits}
}
// Opens the sticker panel from the field's button, in the page, and reports what the very next frame shows.
const openPanel=p=>p.evaluate(()=>new Promise((done,fail)=>{document.querySelector('.composer-action').click();document.querySelector('.composer-tool[data-tool="sticker"]').click();requestAnimationFrame(()=>{try{const s=[...document.querySelectorAll('.sheet')].at(-1);done({skelTabs:s.querySelectorAll('.stk-tab.skel').length,skelCells:s.querySelectorAll('.stk-cell.skel').length,cells:s.querySelectorAll('.stk-cell:not(.skel)').length,text:(b=>(b.querySelectorAll('.stk-fb').forEach(e=>e.remove()),b.textContent.trim()))(s.querySelector('.stk-body').cloneNode(true))})}catch(e){fail(e)}})}))
const box=(p,sel)=>p.evaluate(sel=>{const b=document.querySelector(sel);if(!b)return null;const fb=b.querySelector('.stk-fb'),pic=b.querySelector('.stk-pic');return{ready:b.classList.contains('ready'),instant:b.classList.contains('instant'),emoji:getComputedStyle(fb).visibility==='visible'?fb.textContent||'shape':'',pic:pic?Number(getComputedStyle(pic).opacity):null}},sel)
const incoming=(p,id,st)=>p.evaluate(([id,st])=>import('/js/store.js').then(({upsertMessage})=>upsertMessage({id,chat:'r',type:'sticker',text:'',meta:st,from:'p',out:false,ts:Date.now(),status:'sent'})),[id,st])

;(async()=>{const browser=await chromium.launch();try{
// 1. Nothing fetched ahead and a slow server: the panel shows the shape of its tabs and grid, then the
// add list's rows, never an empty sheet or a loading line.
{const{p,errors}=await page(browser,{listDelay:600,catalogDelay:600,slow:{AgADslow:900,AgADbare:900,AgADcalm:900},gone:['AgADgone']})
const first=await openPanel(p)
assert.deepEqual(first,{skelTabs:2,skelCells:12,cells:0,text:''},'the shape of the panel while the packs come '+JSON.stringify(first))
await sleep(120);await p.screenshot({path:path.join(OUT,'40-stickers-loading.png')})
await p.locator('.sheet.on .stk-cell:not(.skel)').nth(1).waitFor();assert.equal(await p.locator('.sheet.on .skel').count(),0,'then the packs, in place')
await p.click('.sheet.on .stk-tab-add');await sleep(60)
assert.equal(await p.locator('.sheet.on .stk-row.skel').count(),4,'the add list\'s rows while it comes');assert.equal(await p.locator('.sheet.on .stk-body').textContent(),'')
await p.locator('.sheet.on .stk-row:not(.skel)').nth(1).waitFor();assert.equal(await p.locator('.sheet.on .skel').count(),0)
await p.keyboard.press('Escape');await p.locator('.sheet').waitFor({state:'detached'})

// A sticker whose picture is late: nothing for a moment (no flicker), then its emoji, then the picture.
await incoming(p,'s1',{id:'AgADslow',kind:'static',emoji:'🐢',set:'HandDrawnEmoji'});await sleep(50)
assert.deepEqual(await box(p,'.m[data-id="s1"] .stk'),{ready:false,instant:false,emoji:'',pic:0},'a moment: nothing yet')
await sleep(300);assert.deepEqual(await box(p,'.m[data-id="s1"] .stk'),{ready:false,instant:false,emoji:'🐢',pic:0},'then its emoji')
await sleep(1000);assert.deepEqual(await box(p,'.m[data-id="s1"] .stk'),{ready:true,instant:false,emoji:'',pic:1},'then the picture')
// No emoji: a soft shape stands in. No picture at all: the emoji stays.
await incoming(p,'s2',{id:'AgADbare',kind:'static',emoji:'',set:'HandDrawnEmoji'});await sleep(350)
assert.equal((await box(p,'.m[data-id="s2"] .stk')).emoji,'shape')
assert.notEqual(await p.evaluate(()=>getComputedStyle(document.querySelector('.m[data-id="s2"] .stk-fb')).backgroundColor),'rgba(0, 0, 0, 0)')
await incoming(p,'s3',{id:'AgADgone',kind:'static',emoji:'🫥',set:'HandDrawnEmoji'});await sleep(400)
assert.deepEqual(await box(p,'.m[data-id="s3"] .stk'),{ready:false,instant:false,emoji:'🫥',pic:null},'a missing picture leaves the emoji')
// Reduced motion keeps the moment's wait (it is timing, not travel).
await p.emulateMedia({reducedMotion:'reduce'})
await incoming(p,'s4',{id:'AgADcalm',kind:'static',emoji:'🐢',set:'HandDrawnEmoji'});await sleep(50)
assert.equal((await box(p,'.m[data-id="s4"] .stk')).emoji,'','no flicker with reduced motion either')
await sleep(300);assert.equal((await box(p,'.m[data-id="s4"] .stk')).emoji,'🐢')
await p.screenshot({path:path.join(OUT,'41-sticker-placeholders.png')})
assert.deepEqual(errors,[]);await p.close()}

// 2. Fetched ahead: the packs, the opening pack's pictures, the add list and the player, before anyone
// asks; then the panel opens complete, its stickers showing at once, and + shows the list at once.
{const{p,errors,hits}=await page(browser)
assert.deepEqual(hits,[],'nothing fetched before it is wanted')
await p.evaluate(()=>import('/js/views/stickers.js').then(m=>m.prewarmStickers()))
assert.deepEqual([...hits].sort(),['catalog','img:AgADanim?thumb','img:AgADstat','list'],'fetched ahead '+hits)
assert.equal(await p.evaluate(()=>Boolean(window.lottie?.loadAnimation)),true,'the player too')
const opened=await openPanel(p)
assert.deepEqual(opened,{skelTabs:0,skelCells:0,cells:2,text:''},'complete on its first frame '+JSON.stringify(opened))
await sleep(200)
const shown=await p.evaluate(()=>[...document.querySelectorAll('.sheet.on .stk-grid .stk')].map(b=>({ready:b.classList.contains('ready'),instant:b.classList.contains('instant'),emoji:getComputedStyle(b.querySelector('.stk-fb')).visibility})))
assert.deepEqual(shown,[{ready:true,instant:true,emoji:'hidden'},{ready:true,instant:true,emoji:'hidden'}],'pictures at once, no emoji first '+JSON.stringify(shown))
await p.screenshot({path:path.join(OUT,'42-stickers-ready.png')})
const add=await p.evaluate(()=>new Promise(done=>{document.querySelector('.sheet.on .stk-tab-add').click();requestAnimationFrame(()=>done({skel:document.querySelectorAll('.sheet.on .skel').length,rows:document.querySelectorAll('.sheet.on .stk-row').length}))}))
assert.deepEqual(add,{skel:0,rows:2},'the add list at once')
assert.deepEqual(errors,[]);await p.close()}

console.log('PASS: packs, opening pictures, add list and player fetched ahead and nothing before it is wanted; the panel complete on its first frame with its pictures at once; the shape of tabs, grid and rows while anything is still coming; a late picture shows nothing for a moment, then its emoji (or a shape), then itself; a missing one keeps its emoji; the same with reduced motion')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
