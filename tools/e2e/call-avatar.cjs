// The call screen shows the other side's photo: the caller's when they ring you (as the invitation brings it,
// else as this device knows them), the person's or the group's when you call — on voice and video calls
// alike, and it stays until their video actually comes through. Browser-only fixtures; the call service is
// stubbed to wait, so each screen can be looked at. npm run dev:e2e; node tools/e2e/call-avatar.cjs [outdir]
const{chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('fs'),path=require('path')
const BASE=process.env.BASE||'http://127.0.0.1:8787',OUT=process.argv[2]||path.join(process.cwd(),'screenshots-call-avatar')
if(!['127.0.0.1','localhost','[::1]'].includes(new URL(BASE).hostname))throw new Error('Use a local dev server');fs.mkdirSync(OUT,{recursive:true})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const json=body=>({contentType:'application/json',body:JSON.stringify(body)})
// Three small photos, told apart by colour.
const photo=c=>`data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="${c}"/></svg>`)}`
const PEER=photo('#c80'),GROUP=photo('#08c'),KNOWN=photo('#0a4')

;(async()=>{const browser=await chromium.launch({args:['--use-fake-ui-for-media-stream','--use-fake-device-for-media-stream']});try{
const ctx=await browser.newContext({viewport:{width:466,height:678},serviceWorkers:'block',locale:'zh-CN',deviceScaleFactor:2,permissions:['microphone','camera']})
const p=await ctx.newPage(),errors=[];p.on('pageerror',e=>errors.push(e.message));p.setDefaultTimeout(8000)
await p.route('**/auth/status',r=>r.fulfill(json({authed:false})));await p.route('**/api/**',r=>r.fulfill(json({ok:true})))
// The call service answers slowly: the screen stays up to be looked at.
await p.route('**/rtc/**',async r=>{await sleep(4000);r.fulfill({status:503,...json({ok:false,error:'test'})})})
await p.goto(BASE);await p.locator('.auth').waitFor()
await p.evaluate(async([PEER,GROUP,KNOWN])=>{const{state}=await import('/js/store.js'),{createCalls}=await import('/js/views/call.js');state.me={id:'me',display:'我'};state.calls={enabled:true};state.chats=new Map([['r',{id:'r',kind:'dm',room:false,name:'pll',avatar:PEER,peer:{id:'p',display:'pll',avatar:PEER},unread:0}],['g',{id:'g',kind:'group',room:true,name:'周末',avatar:GROUP,unread:0}],['k',{id:'k',kind:'dm',room:false,name:'小红',avatar:KNOWN,peer:{id:'q',display:'小红',avatar:KNOWN},unread:0}]]);window.sent=[];window.calls=createCalls({socketSend:o=>window.sent.push(o),connected:()=>true})},[PEER,GROUP,KNOWN])
// What the poster shows: its photo (once loaded) and whether it can be seen.
const poster=()=>p.evaluate(()=>{const c=document.querySelector('.call'),img=c?.querySelector('.call-poster .avatar img'),pst=c?.querySelector('.call-poster');return{src:img?.getAttribute('src')||null,loaded:Boolean(img?.classList.contains('loaded')&&img.naturalWidth),visible:Boolean(pst&&getComputedStyle(pst).display!=='none'&&pst.getBoundingClientRect().height>0)}})
const hangUp=async()=>{await p.evaluate(()=>document.querySelector('.call .call-btn.hang')?.click());await p.locator('.call').waitFor({state:'detached'}).catch(()=>{});await sleep(300)}

// 1. They call you (video): their photo, as the invitation brought it.
await p.evaluate(PEER=>calls.onSignal({t:'call',kind:'invite',room:'r',callId:'c1',media:'video',from:'p',caller:{id:'p',display:'pll',avatar:PEER}}),PEER);await sleep(500)
assert.deepEqual(await poster(),{src:PEER,loaded:true,visible:true},'the caller\'s photo on an incoming video call')
await p.screenshot({path:path.join(OUT,'50-call-incoming.png')})
await hangUp()

// 2. An invitation without a photo: as this device knows them.
await p.evaluate(()=>calls.onSignal({t:'call',kind:'invite',room:'k',callId:'c2',media:'audio',from:'q',caller:{id:'q',display:'小红'}}));await sleep(500)
assert.deepEqual(await poster(),{src:KNOWN,loaded:true,visible:true},'known from this device')
await hangUp()

// 3. You call (voice, then video): the person's photo, kept up while it connects.
await p.evaluate(()=>calls.start('r','audio'));await sleep(800)
assert.deepEqual(await poster(),{src:PEER,loaded:true,visible:true},'the person you call, on a voice call')
await p.screenshot({path:path.join(OUT,'51-call-outgoing.png')})
await hangUp()
await p.evaluate(()=>calls.start('r','video'));await sleep(1200)
assert.deepEqual(await poster(),{src:PEER,loaded:true,visible:true},'and on a video call, until their video comes through')
await p.screenshot({path:path.join(OUT,'52-call-outgoing-video.png')})
await hangUp()

// 4. A group call: the group's picture.
await p.evaluate(()=>calls.start('g','audio'));await sleep(800)
assert.deepEqual(await poster(),{src:GROUP,loaded:true,visible:true},'the group\'s picture')
await hangUp()

// Never the user id as an image address.
assert.ok(!(await p.evaluate(()=>performance.getEntriesByType('resource').map(e=>new URL(e.name).pathname))).some(n=>/^\/(p|q|me)$/.test(n)),'no request for an id as an image')
assert.deepEqual(errors,[])
console.log('PASS: the caller\'s photo on incoming calls (as sent, else as known here), the person\'s or the group\'s on outgoing voice and video calls, kept while connecting; never an id fetched as an image')
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)})
